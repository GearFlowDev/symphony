defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.Claude.{StreamParser, TmuxCLI}
  alias SymphonyElixir.{Config, Evaluator, Grant, History, Notifier, Planning}
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.Planning.Workflow, as: PlanningWorkflow
  alias SymphonyElixir.{StatusDashboard, Suitability, Tracker, Workspace}

  @continuation_retry_delay_ms 30_000
  # Fixed poll interval while waiting for a shared pool slot to free.
  @no_capacity_retry_delay_ms 45_000
  @max_continuations 5
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      # The task supervisor that owns this orchestrator's agent tasks. Held on
      # the state (not read from the module name) so a test can run an isolated
      # runtime, and so stopping an agent always addresses the supervisor that
      # started it.
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      completed_history: [],
      # Issues blocked for a human this session — never re-dispatched (unlike
      # `completed`, which IS re-assessed each poll so ship gates re-run).
      # A restart clears it: fresh orchestrator, fresh look.
      blocked: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      # The last {candidates, dispatched} pair the poll logged, so an unchanged
      # answer stays silent (GEA-10144).
      last_poll_result: nil
    ]
  end

  # Last successfully-built :snapshot payload, cached in ETS so reads survive a
  # blocked poll cycle. The orchestrator runs LLM grade/plan + Linear HTTP inside
  # handle_info(:run_poll_cycle); while that blocks, a `:snapshot` GenServer.call
  # would time out. Serving the last-known payload (tagged stale) keeps the
  # dashboard showing data instead of "Snapshot unavailable".
  # ponytail: read-cache, not a full poll-cycle-into-Tasks refactor — add that if
  # control calls (stop_issue/retry) also need to stay responsive under load.
  @snapshot_cache :symphony_orchestrator_snapshot

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case validate_workflow_at_boot() do
      :ok ->
        start_polling(opts)

      {:error, reason} ->
        # An invalid WORKFLOW.md used to start a healthy-looking orchestrator
        # that failed every poll cycle instead: `do_dispatch/1` logged the same
        # config error every interval and dispatched nothing, forever. Refuse to
        # start, so the failure is at the boundary where someone reads it
        # (upstream d476215).
        Logger.error("Refusing to start the orchestrator; WORKFLOW.md is invalid: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # `Config.validate!/0` reads through `NimbleOptions.validate!`, which RAISES
  # on a typed-invalid file rather than answering `{:error, _}`. Both are the
  # same refusal here.
  defp validate_workflow_at_boot do
    Config.validate!()
  rescue
    error ->
      {:error, {:invalid_workflow_config, Exception.message(error)}}
  end

  defp start_polling(opts) do
    now_ms = System.monotonic_time(:millisecond)
    ensure_snapshot_cache()

    state = %State{
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      completed_history: load_recent_completed_history(),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    close_orphaned_history_runs()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  # No run survives a restart, so open rows are crash leftovers — close them
  # or they pollute "active runs" queries forever (101 had piled up by 2026-07-14).
  defp close_orphaned_history_runs do
    case History.close_orphaned_runs() do
      0 -> :ok
      count -> Logger.info("Closed #{count} orphaned open run row(s) from prior crashes/restarts")
    end
  rescue
    error ->
      Logger.warning("Failed to close orphaned run rows: #{Exception.message(error)}")
  end

  # Load recent finished runs from SQLite so the dashboard survives restarts.
  defp load_recent_completed_history do
    History.list_runs(limit: 20)
    |> Enum.filter(&(&1.finished_at != nil))
    |> Enum.map(&run_to_history_entry/1)
  rescue
    error ->
      Logger.warning("Failed to load recent completed history: #{Exception.message(error)}")
      []
  end

  defp run_to_history_entry(run) do
    %{
      issue_id: run.issue_identifier || run.issue_id,
      issue_identifier: run.issue_identifier,
      started_at: run.started_at,
      completed_at: run.finished_at,
      phase: run.final_phase,
      phases_seen: [],
      pr_url: run.eval_pr_url,
      outcome: run.outcome || "unknown",
      error: run.error_message,
      last_event: nil,
      last_message: nil,
      turn_count: run.turns_used || 0,
      tokens: %{
        input_tokens: run.input_tokens || 0,
        output_tokens: run.output_tokens || 0,
        total_tokens: run.total_tokens || 0
      }
    }
  end

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    now_ms = System.monotonic_time(:millisecond)
    next_poll_due_at_ms = now_ms + state.poll_interval_ms
    :ok = schedule_tick(state.poll_interval_ms)

    state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_poll_due_at_ms}

    notify_dashboard()
    {:noreply, state}
  end

  # No free pool slot — the worker exited cleanly before doing anything (the
  # pool is shared with interactive sessions). Not a crash: skip grading/history/
  # slot-release and requeue quietly with a fixed backoff until a slot frees.
  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, :no_capacity}}, %{running: running} = state) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)

        Logger.info("No pool slot for issue_id=#{issue_id} identifier=#{running_entry[:identifier]}; backing off")

        # Close the run row opened at dispatch — skipping history here left
        # these 0-turn rows open forever (101 piled up by 2026-07-14). A
        # distinct outcome keeps them out of failure stats.
        with run_id when is_binary(run_id) <- Map.get(running_entry, :history_run_id),
             {:error, reason} <-
               History.record_completion(run_id, %{
                 finished_at: DateTime.utc_now(),
                 outcome: "no_capacity",
                 error_category: "no_capacity"
               }) do
          Logger.warning("Failed to close no_capacity run row #{run_id}: #{inspect(reason)}")
        end

        state =
          schedule_issue_retry(state, issue_id, 1, %{
            identifier: running_entry[:identifier],
            delay_type: :no_capacity
          })

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        {state, _eval_result} = record_completed_history(state, running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        # Grade the plan dispatch (if any) BEFORE releasing the slot — the
        # Grader reads the worker's diff from the slot, which slot release
        # resets. Synchronous so the refreshed row states are persisted before
        # any retask continuation re-assesses the plan.
        maybe_grade_plan_dispatch(running_entry)

        # Release the pool slot immediately — the agent process is done.
        # If the issue gets retasked/retried, the slot will be re-claimed on next dispatch.
        release_pool_slot_async(running_entry[:identifier])

        state = schedule_after_agent_exit(state, issue_id, session_id, running_entry, reason)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        # Record phase transition events
        record_phase_transition_events(running_entry, updated_running_entry, issue_id)

        # Detect SYMPHONY_NEEDS_HELP marker
        raw_event = Map.get(update, :raw)
        already_flagged = Map.get(running_entry, :needs_human, false)
        updated_running_entry = flag_needs_help(updated_running_entry, issue_id, raw_event, already_flagged)

        # Record the tester's machine verdict (SYMPHONY_VERDICT marker) to the DB.
        maybe_record_tester_verdict(running_entry, raw_event)

        updated_running_entry = maybe_persist_run_progress(updated_running_entry)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:agent_needs_help, issue_id, message}, %{running: running} = state) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning("Agent needs help: issue_id=#{issue_id} identifier=#{identifier} session_id=#{session_id}; message=#{message}")

        # Notify via Linear comment and webhook
        Notifier.notify(:needs_human, %{
          issue_id: issue_id,
          identifier: identifier,
          help_message: message
        })

        # The run is over, whatever a person does next.
        clear_working_label(issue_id, identifier)

        # Move issue to review state if configured (Shaping on the Gearflow boxes).
        move_issue_to_needs_human_state(issue_id, identifier, Config.escalation_needs_human_state())

        # Record escalation in history
        run_id = Map.get(running_entry, :history_run_id)

        if is_binary(run_id) do
          History.record_escalation(run_id, "needs_human", message)
        end

        # Terminate the agent
        state = terminate_running_issue(state, issue_id, false, :needs_help)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp release_pool_slot_async(identifier) do
    if identifier do
      Task.start(fn -> Workspace.release_pool_slot_for_issue(identifier) end)
    end
  end

  defp schedule_after_agent_exit(state, issue_id, session_id, running_entry, :normal) do
    continuation_count = Map.get(running_entry, :continuation_count, 0) + 1

    if continuation_count > @max_continuations do
      Logger.warning("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; reached max continuations (#{@max_continuations}), completing")

      complete_issue(state, issue_id)
    else
      # The plan is the sole authority. The dispatch this run produced was
      # already graded above (row states are fresh). Schedule a continuation
      # that re-assesses the plan on the next dispatch — plan_action/2 then
      # decides whether to dispatch the remaining open rows (Implement),
      # dispatch the tester (Test), finish the issue, or block it.
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling plan continuation #{continuation_count}/#{@max_continuations}")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, continuation_count, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        continuation_count: continuation_count
      })
    end
  end

  defp schedule_after_agent_exit(state, issue_id, session_id, running_entry, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}"
    })
  end

  # Detect SYMPHONY_NEEDS_HELP marker
  defp flag_needs_help(running_entry, issue_id, raw_event, already_flagged) do
    needs_help_message = if raw_event, do: StreamParser.extract_needs_help(raw_event)

    if needs_help_message && !already_flagged do
      send(self(), {:agent_needs_help, issue_id, needs_help_message})
      Map.merge(running_entry, %{needs_human: true, needs_human_message: needs_help_message})
    else
      running_entry
    end
  end

  # Record the tester's machine verdict (SYMPHONY_VERDICT marker) to the DB.
  # The gate reads this record — not the human-facing Linear report — so a
  # verdict can't be lost to wording variance or a report posted to GitHub.
  defp maybe_record_tester_verdict(_running_entry, raw_event) when raw_event in [nil, false], do: nil

  defp maybe_record_tester_verdict(running_entry, raw_event) do
    case StreamParser.extract_verdict(raw_event) do
      {verdict, sha, reason} ->
        if identifier = Map.get(running_entry, :identifier),
          do: History.record_tester_verdict(identifier, verdict, sha, reason)

      _ ->
        :ok
    end
  end

  # Move issue to review state if configured. On the Gearflow boxes that is
  # `Shaping`, which is where parking lives: nothing dispatches from it, and
  # the `needs-human` label this used to reach for was retired 2026-09-17.
  defp move_issue_to_needs_human_state(issue_id, identifier, needs_human_state) when is_binary(needs_human_state) do
    case Tracker.update_issue_state(issue_id, needs_human_state) do
      :ok ->
        Logger.info("Moved issue #{identifier} to state '#{needs_human_state}'")

      {:error, reason} ->
        Logger.warning("Failed to move issue #{identifier} to '#{needs_human_state}': #{inspect(reason)}")
    end
  end

  defp move_issue_to_needs_human_state(_issue_id, _identifier, _needs_human_state), do: nil

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    # Free slots whose lock no longer backs a running issue (e.g. a run that
    # ended without its slot release firing). Runs every poll so abandoned
    # locks don't silently shrink effective concurrency. Off under :test
    # (`reap_orphans: false`): a test BEAM's empty running set would otherwise
    # make every live worker on this host look orphaned.
    if Application.get_env(:symphony_elixir, :reap_orphans, true) do
      reap_stale_pool_locks(state)
      reap_orphan_tmux_sessions(state)
    end

    if Config.within_active_hours?() do
      state
      |> check_completed_pr_health()
      |> do_dispatch()
    else
      Logger.debug("Outside active hours, skipping dispatch")
      state
    end
  end

  defp reap_stale_pool_locks(%State{running: running}) do
    running
    |> Map.values()
    |> Enum.map(& &1[:identifier])
    |> Enum.reject(&is_nil/1)
    |> Workspace.reap_stale_pool_locks()

    :ok
  end

  # Kill tmux Claude sessions that no longer back a running worker — the safety
  # net for sessions leaked when a worker was terminated without its
  # `stop_session/1` cleanup firing (see `terminate_running_issue/4`). Scoped to
  # the running set so a live worker's session is never reaped.
  defp reap_orphan_tmux_sessions(%State{running: running}) do
    active_session_ids =
      running
      |> Map.values()
      |> Enum.map(& &1[:session_id])
      |> Enum.reject(&is_nil/1)

    # 120s grace: a just-launched worker's tmux session exists before its
    # session_id propagates into `running`, so don't reap young sessions.
    case TmuxCLI.reap_orphan_sessions_except(active_session_ids, min_age_seconds: 120) do
      [] -> :ok
      reaped -> Logger.info("Reaped #{length(reaped)} orphaned Claude tmux session(s): #{inspect(reaped)}")
    end

    :ok
  end

  defp do_dispatch(%State{} = state) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      dispatched =
        if available_slots(state) > 0 do
          choose_issues(issues, state)
        else
          state
        end

      log_poll_result(state, issues, dispatched)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_filter} ->
        Logger.error("No Linear targeting configured in WORKFLOW.md (need filter with labels or teams)")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, :missing_codex_command} ->
        Logger.error("Codex command missing in WORKFLOW.md")
        state

      {:error, {:invalid_codex_approval_policy, value}} ->
        Logger.error("Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_codex_thread_sandbox, value}} ->
        Logger.error("Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}")
        state

      {:error, {:invalid_codex_turn_sandbox_policy, reason}} ->
        Logger.error("Invalid codex.turn_sandbox_policy in WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  # One line per poll, and only when the answer moves. A poller that prints its
  # result every interval refills a bounded log window the way the status board
  # did (GEA-10144); a poller that never prints leaves "was it even looking?"
  # unanswerable after an incident. So: print the counts when they change, and
  # stay quiet while they do not.
  defp log_poll_result(%State{running: before_running}, issues, %State{} = state) do
    result = {length(issues), max(map_size(state.running) - map_size(before_running), 0)}

    if result == state.last_poll_result do
      state
    else
      {candidates, dispatched} = result
      Logger.info("Poll: candidates=#{candidates} dispatched=#{dispatched} running=#{map_size(state.running)}")
      %{state | last_poll_result: result}
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          reconcile_running_issue_states(
            issues,
            state,
            active_state_set(),
            terminal_state_set()
          )

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec terminate_running_issue_for_test(term(), String.t(), boolean(), atom()) :: term()
  def terminate_running_issue_for_test(%State{} = state, issue_id, cleanup_workspace, reason) do
    terminate_running_issue(state, issue_id, cleanup_workspace, reason)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec plan_cycle_fingerprint_for_test(term(), String.t(), String.t() | nil) :: String.t()
  def plan_cycle_fingerprint_for_test(plan, identifier, pr_url) do
    plan_cycle_fingerprint(plan, identifier, pr_url)
  end

  @doc false
  @spec no_progress_message_for_test(pos_integer(), pos_integer(), String.t(), String.t()) :: String.t()
  def no_progress_message_for_test(repeats, limit, fingerprint, identifier) do
    no_progress_message(repeats, limit, fingerprint, identifier)
  end

  @doc false
  @spec handle_active_retry_for_test(Issue.t(), term(), pos_integer(), map()) :: term()
  def handle_active_retry_for_test(%Issue{} = issue, %State{} = state, attempt, metadata) do
    {:noreply, new_state} = handle_active_retry(state, issue, attempt, metadata)
    new_state
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, :terminal_state)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :not_routable)

      # The candidate QUERY filters on the routing label, so a label removed
      # mid-run never reaches this loop through the query — but the by-id
      # refresh carries the live labels, and this is the only place that reads
      # them. Without this arm, taking the label off a running issue changed
      # nothing until the agent finished on its own, holding its slot the whole
      # time (upstream 54b456b). Cleanup is on: releasing the slot IS the point.
      !issue_carries_required_labels?(issue) ->
        Logger.info("Required label removed from issue: #{issue_context(issue)} labels=#{inspect(issue.labels)}; stopping active agent and releasing its slot")

        terminate_running_issue(state, issue.id, true, :label_removed)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_active_state)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  # `:stalled` is the one reason a retry follows, so it is the one reason the live
  # mark stays on. Every other reason ends Symphony's interest in the issue — a
  # person moved it, took the label off, or stopped it from the dashboard — and a
  # new reason added here inherits the removal rather than having to ask for it.
  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, reason) do
    if reason != :stalled do
      clear_working_label(issue_id, running_identifier(state, issue_id))
    end

    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        {state, _eval_result} = record_completed_history(state, running_entry, {:terminated, reason})

        # Grade any plan dispatch before workspace cleanup wipes the diff.
        maybe_grade_plan_dispatch(running_entry)

        # STOP THE WORKER FIRST. `before_remove` releases the pool slot, and a
        # worker still alive while that runs goes on writing into a slot the
        # registry has already handed to someone else.
        if is_pid(pid) do
          terminate_task(pid, state.task_supervisor)
        end

        # Killing the BEAM task is not enough: the worker's Claude runs in a
        # tmux session that outlives the task (the runner's `after`-block
        # cleanup doesn't fire under an external kill). Kill it explicitly so a
        # terminated/restarted worker can't keep editing its slot.
        TmuxCLI.kill_by_session_id(Map.get(running_entry, :session_id))

        # Nor is the task enough for a hook: closing its port kills `sh` and
        # leaves the provisioner it spawned running. An abandoned `before_run`
        # went on to claim a second slot for this same issue (GEA-9889).
        kill_running_hook(running_entry)

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        if cleanup_workspace do
          cleanup_issue_workspace(running_entry, identifier)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp running_identifier(%State{running: running}, issue_id) do
    case Map.get(running, issue_id) do
      %{identifier: identifier} when is_binary(identifier) -> identifier
      _ -> issue_id
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.agent_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)
    phase_elapsed_ms = phase_stall_elapsed_ms(running_entry, now)
    timeout_ms = bootstrap_aware_timeout(running_entry, timeout_ms)
    phase_timeout_ms = timeout_ms * 2

    stall_reason =
      cond do
        is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
          "stalled for #{elapsed_ms}ms without codex activity"

        is_integer(phase_elapsed_ms) and phase_elapsed_ms > phase_timeout_ms ->
          "phase stuck for #{phase_elapsed_ms}ms (phase=#{Map.get(running_entry, :phase)})"

        true ->
          nil
      end

    if stall_reason do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}; #{stall_reason}; restarting with backoff")

      Notifier.notify(:agent_stalled, %{
        issue_id: issue_id,
        identifier: identifier,
        stall_reason: stall_reason,
        session_id: session_id
      })

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false, :stalled)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: stall_reason
      })
    else
      state
    end
  end

  # The clock starts at dispatch, but the agent does not: `before_run` runs
  # first, and a provisioning hook is not an inactive agent. Until a session id
  # exists there is no agent to be stalled, and the hook has its OWN timeout
  # bounding that window — so never abandon a run inside it for less than the
  # hook's own budget. This is what killed runs mid-provision and made every
  # retry fail the same way (TODO.md, GEA-4619/4625), and what `WORKFLOW.md`'s
  # "keep codex.stall_timeout_ms >= hooks.timeout_ms" note was standing in for.
  defp bootstrap_aware_timeout(running_entry, timeout_ms) do
    case running_entry_session_id(running_entry) do
      session_id when is_binary(session_id) and session_id != "n/a" ->
        timeout_ms

      _ ->
        # TWO hook budgets: `after_create` runs inside `create_for_issue/1` and
        # `before_run` follows it, both before any session exists. One budget
        # would still cut a slow provision off partway through the second.
        max(timeout_ms, Config.hook_timeout_ms() * 2)
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    result =
      candidate_issue?(issue, active_states, terminal_states) and
        !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
        suitable_issue?(issue) and
        !MapSet.member?(state.blocked, issue.id) and
        !MapSet.member?(claimed, issue.id) and
        !Map.has_key?(running, issue.id) and
        available_slots(state) > 0 and
        state_slots_available?(issue, running)

    result
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp suitable_issue?(%Issue{} = issue) do
    case Suitability.screen(issue) do
      :ok ->
        true

      {:skip, reason} ->
        Logger.info("Skipping unsuitable issue #{issue.identifier}: #{reason}")
        false
    end
  end

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  # NO labels is missing evidence, not proof of removal: a routed issue carries
  # at least the routing label, so an empty list means the refresh did not
  # project labels at all. Stopping an agent and wiping its slot on that would
  # turn a thin Linear response into lost work. Only a label set that IS present
  # and lacks a required label proves the label was taken off.
  defp issue_carries_required_labels?(%Issue{labels: []}), do: true

  defp issue_carries_required_labels?(%Issue{labels: labels}) when is_list(labels) do
    case Config.required_issue_labels() do
      [] ->
        true

      required ->
        # ANY, not all. The candidate query compiles `labels.include` to
        # `labels: {name: {in: [...]}}`, which Linear matches on any one of
        # them. A stricter live gate than the query means the poll dispatches an
        # issue and this arm stops it again on the very next cycle.
        issue_labels = MapSet.new(labels, &normalize_label/1)
        Enum.any?(required, &MapSet.member?(issue_labels, normalize_label(&1)))
    end
  end

  defp issue_carries_required_labels?(_issue), do: true

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(label), do: to_string(label)

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, metadata \\ %{}) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_refreshed_issue(state, refreshed_issue, attempt, metadata)

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  rescue
    error ->
      Logger.error("dispatch_issue crashed for #{issue_context(issue)}: #{Exception.message(error)}")
      state
  end

  # Split out of `dispatch_issue/4` so a RETRY can act on the refresh outcome
  # instead of dropping the issue. Every caller used to get `state` back for all
  # three non-ok outcomes, which on the retry path left the issue claimed and out
  # of the retry queue for good (TODO.md "A transient Linear error during a retry
  # poll drops the issue for good", 2026-09-15; upstream 0517275).
  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The rescue lives HERE, not only on `dispatch_issue/4`: the retry path calls
  # this directly, and everything that can raise — `spawn_worker/4`,
  # `record_dispatch_to_history/3`, `Tracker.claim_issue/2` — is below this
  # line. Leaving it on the caller meant a raise on the retry path took the
  # orchestrator down with it.
  defp dispatch_refreshed_issue(%State{} = state, %Issue{} = refreshed_issue, attempt, metadata) do
    # Find the issue's open PR (if any) so the plan workflow assesses against
    # the right branch, and the worker checks it out. The plan — not a phase
    # judge — decides what to dispatch; that happens in do_dispatch_issue.
    # The evaluator's stored PR wins over the branch-name search: the search
    # guesses by prefix and picks the wrong sibling when two open branches
    # share the issue identifier (GEA-5377: #2388 shadowed #2385).
    {pr_url, pr_branch} =
      case stored_pr(refreshed_issue) || attachment_pr(refreshed_issue) ||
             check_existing_pr(refreshed_issue) do
        {:pr_exists, url, branch} -> {url, branch}
        :no_pr -> {nil, nil}
      end

    # Carry the resolved PR on the issue so slot routing (workspace hooks)
    # leases the PR's repo, not the repo the product label guesses.
    refreshed_issue = %{refreshed_issue | pr_url: pr_url}

    pr_metadata = %{existing_pr_url: pr_url, existing_pr_branch: pr_branch}
    do_dispatch_issue(state, refreshed_issue, attempt, Map.merge(metadata, pr_metadata))
  rescue
    error ->
      Logger.error("dispatch_issue crashed for #{issue_context(refreshed_issue)}: #{Exception.message(error)}")
      state
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, metadata) do
    # The plan is the sole dispatch authority. plan_action/2 generates the plan
    # on an issue's first dispatch (one LLM call) and reuses it after, then says
    # whether to dispatch a worker (Implement row-closer or Test tester), finish
    # the issue, or block it for a human.
    case plan_action(issue, metadata) do
      {:dispatch, metadata} ->
        spawn_worker(state, issue, attempt, metadata)

      :done ->
        Logger.info("Plan complete and tester-approved for #{issue_context(issue)}; completing issue")
        finish_run(issue, metadata[:existing_pr_url])
        clear_working_label(issue.id, issue.identifier)
        complete_issue(state, issue.id)

      {:blocked, reason} ->
        block_issue_for_plan_failure(state, issue, reason)
    end
  end

  # THE ONE ENDING A RUN HAS: a PR exists, and under a grant that hands off, the
  # hand-off comment is posted on it. A run that ends without a PR is broken, not
  # handed off — the machine owner's rule of 2026-09-22 (GEA-9888).
  #
  # Best-effort + off the orchestrator loop: never let a gh or a Linear hiccup
  # stall dispatch.
  defp finish_run(issue, pr_url) do
    identifier = Map.get(issue, :identifier)

    if is_binary(identifier) do
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        try do
          url = pr_url || ensure_pr_for_issue(issue)
          hand_off(issue, url)
        rescue
          error ->
            Logger.warning("finish_run failed for #{identifier}: #{Exception.message(error)}")
        end
      end)
    end

    :ok
  end

  # THE PR THIS RUN MUST LEAVE BEHIND. Returns its URL, opening one when the
  # branch is pushed and has none.
  #
  # The cheap answers first: the PR the evaluator recorded, then the one the
  # Linear-GitHub integration attached. Only when neither answers does this reach
  # for the issue's slot — `before_remove` keeps it leased between dispatches, so
  # `gh` resolves the repo from that checkout and needs no `--repo` guess.
  #
  # Never fatal. This runs on the orchestrator loop from the park guard, and a
  # `gh` that is slow or unauthenticated must not take the poller down with it.
  defp ensure_pr_for_issue(issue) do
    identifier = Map.get(issue, :identifier)

    case stored_pr(issue) || attachment_pr(issue) do
      {:pr_exists, url, _branch} ->
        url

      _ ->
        case Workspace.slot_lease_for_issue(identifier) do
          {slot_dir, lease_branch} ->
            Evaluator.ensure_pr_open(
              slot_dir,
              first_present([lease_branch, Map.get(issue, :branch_name)]),
              "#{identifier}: #{Map.get(issue, :title)}",
              pr_body(issue)
            )

          _ ->
            Logger.warning("No slot leased to #{identifier} and no PR on it; none could be opened")
            nil
        end
    end
  rescue
    error ->
      Logger.warning("ensure_pr_for_issue failed for #{issue_context(issue)}: #{Exception.message(error)}")
      nil
  end

  defp pr_body(issue) do
    identifier = Map.get(issue, :identifier)
    url = Map.get(issue, :url)

    ["Linear: #{identifier}", url]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp first_present(values) do
    Enum.find(values, fn value -> is_binary(value) and value != "" end)
  end

  # HAND THE PR TO WHOEVER MERGES IT. Under `Auto-Merge` and `Auto-User` that is
  # the harness, which judges from one tooling-written comment (GEA-9955) and
  # never from a bare branch. Under `Auto-Build` and `Auto-Design` a person
  # merges, so there is nothing to hand to a machine and this is a no-op.
  defp hand_off(issue, pr_url) do
    grant = Grant.of(Map.get(issue, :labels))
    identifier = Map.get(issue, :identifier)

    cond do
      not Grant.hands_off?(grant) ->
        Logger.info("#{identifier} holds #{Grant.label(grant)}; a person merges, so no hand-off is posted")
        :ok

      is_nil(Config.hand_off_command()) ->
        Logger.info("No hand_off.command configured; #{identifier} ends at its PR")
        :ok

      not is_binary(pr_url) ->
        Logger.warning("#{identifier} finished with no PR to hand off — the run is incomplete")
        :error

      already_handed_off?(issue, pr_url) ->
        Logger.info("#{identifier} is already handed off at #{pr_url}'s head commit; nothing to post")
        :ok

      true ->
        run_hand_off_command(issue, pr_url)
    end
  end

  # HAS THIS EXACT COMMIT ALREADY BEEN HANDED OFF? It has to be asked, because a completed
  # issue is re-assessed every poll — that is what re-runs the ship gates — so the `:done`
  # arm fires again roughly every two minutes for as long as the issue sits in In Review.
  # Without this the hand-off comment would repost on that cadence until somebody moved the
  # issue, and Linear's hourly write limit is shared by the whole workspace.
  #
  # KEYED ON THE HEAD COMMIT, not on the PR. A later dispatch — Fix CI, Resolve Review —
  # pushes new commits, and the harness judges a hand-off against the commit it names. A new
  # commit is a new thing to judge and deserves a fresh hand-off; the same commit is not.
  #
  # A READ THAT FAILS ANSWERS "no". A hand-off that never posts strands the work with nobody
  # told; a second hand-off supersedes the first (GEA-9955), which is the cheaper mistake.
  defp already_handed_off?(issue, pr_url) do
    # `pr_head_sha/1` answers with the first 12 characters, or "?" when `gh` cannot say.
    # "?" is not an answer, so it means "post the hand-off".
    with short when is_binary(short) and short != "?" <- pr_head_sha(pr_url),
         {:ok, comments} <- Client.fetch_all_issue_comments(Map.get(issue, :id)) do
      handed_off_for_sha?(comments, short)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc false
  @spec handed_off_for_sha?([map()], String.t()) :: boolean()
  def handed_off_for_sha?(comments, short_sha) when is_list(comments) and is_binary(short_sha) do
    # A PREFIX IS ENOUGH. The marker carries the full oid, so `sha=<12 chars>` matches that
    # marker and no other commit's. Both halves are required: a comment that merely quotes a
    # sha is not a hand-off, and a hand-off for another commit is not this one.
    Enum.any?(comments, fn comment ->
      body = Map.get(comment, :body) || ""
      String.contains?(body, "gf:handoff") and String.contains?(body, "sha=" <> short_sha)
    end)
  end

  def handed_off_for_sha?(_comments, _short_sha), do: false

  defp run_hand_off_command(issue, pr_url) do
    identifier = Map.get(issue, :identifier)
    proof_path = Path.join(System.tmp_dir!(), "symphony-handoff-#{identifier}.md")
    File.write!(proof_path, hand_off_proof(issue, pr_url))

    env = [
      {"SYMPHONY_ISSUE_IDENTIFIER", identifier},
      {"SYMPHONY_ISSUE_ID", to_string(Map.get(issue, :id))},
      {"SYMPHONY_PR_URL", pr_url},
      {"SYMPHONY_PROOF_FILE", proof_path}
    ]

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", Config.hand_off_command()], env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, Config.hand_off_timeout_ms()) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        Logger.info("Handed #{identifier} off at #{pr_url}: #{String.trim(output)}")
        File.rm(proof_path)
        :ok

      {:ok, {output, code}} ->
        Logger.error("Hand-off for #{identifier} exited #{code}; the proof stays at #{proof_path}: #{String.trim(output)}")
        :error

      _ ->
        Logger.error("Hand-off for #{identifier} timed out after #{Config.hand_off_timeout_ms()}ms")
        :error
    end
  end

  # The proof the hand-off carries: what the plan closed, how the tester confirmed
  # it, and where to look. Assembled from Symphony's own record rather than asked
  # of the agent — a proof a model must remember to write goes missing (GEA-9955).
  defp hand_off_proof(issue, pr_url) do
    identifier = Map.get(issue, :identifier)

    plan_section =
      case Planning.get_plan_by_issue(identifier) do
        %Planning.Plan{} = plan -> Planning.render_plan_comment(plan)
        _ -> "## Plan\n\n_(Symphony kept no plan for this issue.)_"
      end

    tester_section =
      case History.latest_tester_verdict(identifier) do
        %{verdict: verdict} = record ->
          reason = Map.get(record, :reason)
          base = "## Tester\n\nVerdict: **#{verdict}**"
          if is_binary(reason) and reason != "", do: base <> "\n\n#{reason}", else: base

        _ ->
          "## Tester\n\n_(no tester verdict recorded)_"
      end

    """
    **#{identifier} is built and its PR is ready to judge.** Symphony closed the plan below and the tester approved it.

    #{plan_section}

    #{tester_section}

    ## How to confirm

    - The PR and its checks: #{pr_url}
    - Symphony's plan mirror and tester report are the comments above this one.
    """
  end

  # THE LIVE-RUN MARK. `symphony-working` goes on when Symphony claims an issue and
  # comes off at every ending, mirroring the agent pool's `auto-working`. The pool's
  # reaper and liveness sweep match `auto-working` and nothing else, so this label
  # tells a person which issues are live here without making the pool touch them
  # (GEA-9888). Configured per machine: `tracker.working_label`, nil to leave the
  # board unmarked.
  defp mark_working_label(issue_id, identifier), do: update_working_label(:add, issue_id, identifier)

  defp clear_working_label(issue_id, identifier), do: update_working_label(:remove, issue_id, identifier)

  defp update_working_label(op, issue_id, identifier) when is_binary(issue_id) do
    case Config.tracker_working_label() do
      label when is_binary(label) and label != "" ->
        # Off the orchestrator loop and never fatal: an unmarked board is a smaller
        # failure than a dispatch that Linear held up.
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          apply_working_label(op, issue_id, identifier, label)
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp update_working_label(_op, _issue_id, _identifier), do: :ok

  defp apply_working_label(op, issue_id, identifier, label) do
    result =
      case op do
        :add -> Tracker.add_label(issue_id, label)
        :remove -> Tracker.remove_label(issue_id, label)
      end

    case result do
      :ok ->
        Logger.info("#{op} #{label} on #{identifier}")

      {:error, reason} ->
        Logger.warning("Could not #{op} #{label} on #{identifier}: #{inspect(reason)}")
    end
  end

  defp spawn_worker(%State{} = state, issue, attempt, metadata) do
    recipient = self()

    runner = Config.agent_runner_module()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           runner.run(issue, recipient,
             attempt: attempt,
             retask_phases: metadata[:retask_phases],
             completed_phases: metadata[:completed_phases],
             existing_pr_url: metadata[:existing_pr_url],
             existing_pr_branch: metadata[:existing_pr_branch],
             assigned_rows: metadata[:assigned_rows],
             plan_rows: metadata[:plan_rows],
             plan_dispatch_id: metadata[:plan_dispatch_id],
             model: metadata[:model]
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        # Claim the issue in Linear: move to "In Progress" and assign to us.
        # An issue already In Review (ready PR, CodeRabbit engaged) keeps that
        # state — a CR-triage dispatch must not demote it back to In Progress.
        claim_state =
          if is_binary(issue.state) and normalize_issue_state(issue.state) == "in review",
            do: "In Review",
            else: "In Progress"

        case Tracker.claim_issue(issue.id, claim_state) do
          :ok ->
            Logger.info("Claimed issue in Linear: #{issue_context(issue)}")

          {:error, reason} ->
            Logger.warning("Failed to claim issue in Linear: #{issue_context(issue)} reason=#{inspect(reason)}")
        end

        # The live mark goes on with the claim, and comes off at every ending.
        # Idempotent, so a re-dispatch of a running issue re-asserts it for free.
        mark_working_label(issue.id, issue.identifier)

        # Remove any stale completed_history entry if this issue is being re-dispatched
        completed_history =
          Enum.reject(state.completed_history, fn entry ->
            entry[:issue_identifier] == issue.identifier
          end)

        now = DateTime.utc_now()
        history_run_id = record_dispatch_to_history(issue, attempt, now)

        # Tokens already spent on this issue across prior (now-finished) runs.
        # Seeds the fresh attempt so the dashboard reports the issue's running
        # total rather than dropping to 0 each time an agent restarts.
        prior_tokens = History.issue_token_totals(issue.identifier)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            # Recorded, not recomputed: cleanup must aim at the directory this
            # dispatch actually created, whatever `workspace.root` says later.
            workspace_path: Workspace.path_for_issue(issue.identifier),
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            prior_issue_input_tokens: prior_tokens.input_tokens,
            prior_issue_output_tokens: prior_tokens.output_tokens,
            prior_issue_total_tokens: prior_tokens.total_tokens,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            phase: nil,
            pr_url: nil,
            retry_attempt: normalize_retry_attempt(attempt),
            continuation_count: Map.get(metadata, :continuation_count, 0),
            started_at: now,
            phase_changed_at: now,
            phases_seen: [],
            screenshot_urls: [],
            history_run_id: history_run_id,
            plan_dispatch_id: Map.get(metadata, :plan_dispatch_id)
          })

        %{
          state
          | running: running,
            completed_history: completed_history,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  # --- Planning integration --------------------------------------------------
  #
  # The plan is the sole dispatch authority — there is no phase judge. Every
  # dispatch runs plan_action/2, which generates the plan on an issue's first
  # dispatch and reuses it after, then decides:
  #
  #   * Plan has open rows → dispatch an Implement row-closer for them, record a
  #     Dispatch (so completion can grade it).
  #   * Plan code rows all done → consult the tester:
  #       - never tested / code changed since the last report → dispatch the Test
  #         tester sub-agent.
  #       - fresh tester REQUEST_CHANGES → reopen the done rows and dispatch an
  #         Implement row-closer to address the gaps (the tester can't edit code).
  #       - fresh tester APPROVE → enforce the ship gate (CI green AND no
  #         requested-changes review). Pass → done. Fail → reopen the rows and
  #         dispatch an Implement row-closer to fix CI / address the review.
  #   * Plan generation failed → block the issue and notify a human.
  #
  # Returns {:dispatch, metadata} | :done | {:blocked, reason}.
  #
  # Two guards wrap the decision (GEA-4625/4621 churn, 2026-07-15: 50 and 42
  # dispatches against already-green PRs). Both escalate to a human via the
  # ordinary {:blocked, _} path — escalation IS the amendment path; the plan
  # itself is never revised autonomously.
  #
  #   * Daily dispatch budget: hard cap on worker dispatches per issue per
  #     UTC day, whatever the phase mix. Makes a 374-run issue impossible.
  #   * No-progress breaker: if the same (row states + tester verdict)
  #     fingerprint keeps coming back across finished runs, the plan/grader/
  #     tester standoff will never converge — stop dispatching.
  defp plan_action(issue, metadata) do
    case dispatch_budget_check(issue) do
      :ok ->
        case plan_action_decision(issue, metadata) do
          {:dispatch, _} = result -> no_progress_check(issue, result)
          other -> other
        end

      {:blocked, _} = blocked ->
        blocked
    end
  end

  defp plan_action_decision(issue, metadata) do
    case PlanningWorkflow.assess(issue, pr_url: metadata[:existing_pr_url]) do
      {:ok, {:has_open_rows, plan, rows}} ->
        dispatch_implement(issue, metadata, plan, rows, "#{length(rows)} open rows")

      {:ok, {:complete, plan}} ->
        complete_plan_action(issue, metadata, plan)

      {:error, reason} ->
        {:blocked, {:plan_assess_failed, reason}}
    end
  rescue
    error ->
      {:blocked, {:plan_action_crashed, Exception.message(error)}}
  end

  defp dispatch_budget_check(issue) do
    limit = Config.max_dispatches_per_issue_per_day()
    used = History.dispatches_today(Map.get(issue, :identifier))

    if used >= limit do
      {:blocked,
       {:dispatch_budget_exhausted,
        "#{used} dispatches since 00:00 UTC (limit #{limit}) — a converging issue " <>
          "finishes in far fewer; something is looping. Review the plan and recent " <>
          "run outcomes. The count resets at 00:00 UTC; re-activate the issue to " <>
          "resume before then."}}
    else
      :ok
    end
  rescue
    # The budget guard must never take down dispatch itself.
    error ->
      Logger.warning("dispatch_budget_check failed for #{issue_context(issue)}: #{Exception.message(error)}")
      :ok
  end

  # Cycle fingerprint = plan row states + latest tester verdict. The GEA-4625
  # standoff alternates between a small set of states (rows reopen → implement
  # → grader re-rejects → rows reopen …), so consecutive-equality misses it;
  # instead keep a short history and trip when the same state recurs N times.
  # Only append when a run has FINISHED since the last append, so no-capacity
  # retries and poll cycles don't inflate the count.
  defp no_progress_check(issue, {:dispatch, dispatch_metadata} = result) do
    identifier = Map.get(issue, :identifier)
    limit = Config.plan_cycle_repeat_limit()

    case Planning.get_plan_by_issue(identifier) do
      nil ->
        result

      plan ->
        finished = History.finished_run_count(identifier)
        meta = plan.metadata || %{}
        last_seen = meta["cycle_run_count"] || 0

        if finished > last_seen do
          record_plan_cycle(plan, meta, finished, identifier, limit, dispatch_metadata, result)
        else
          result
        end
    end
  rescue
    # The breaker must never take down dispatch itself.
    error ->
      Logger.warning("no_progress_check failed for #{issue_context(issue)}: #{Exception.message(error)}")
      result
  end

  defp record_plan_cycle(plan, meta, finished, identifier, limit, dispatch_metadata, result) do
    fingerprint =
      plan_cycle_fingerprint(plan, identifier, dispatch_metadata[:existing_pr_url])

    history = Enum.take([fingerprint | meta["cycle_history"] || []], 4 * limit)
    repeats = Enum.count(history, &(&1 == fingerprint))
    tripped? = repeats >= limit

    # Tripping resets the history: a human re-activating the issue gets a
    # fresh breaker budget instead of an instant re-trip.
    {:ok, _} =
      Planning.update_plan(plan, %{
        metadata:
          Map.merge(meta, %{
            "cycle_history" => if(tripped?, do: [], else: history),
            "cycle_run_count" => finished
          })
      })

    if tripped? do
      {:blocked, {:no_progress, no_progress_message(repeats, limit, fingerprint, identifier)}}
    else
      result
    end
  end

  # Name only the gates that actually ran. The fixed text blamed "plan, grader,
  # and tester" on every trip, including the pre-PR ones where no tester had
  # ever been dispatched — the person reading it went looking for a tester
  # disagreement that did not exist (first Fly run, GEA-9889, 2026-09-22).
  defp no_progress_message(repeats, limit, fingerprint, identifier) do
    gates =
      case History.latest_tester_verdict(identifier) do
        %{verdict: _verdict} -> "plan, grader and tester are not converging"
        _ -> "the plan and the grader are not converging; the tester has not run yet"
      end

    "the dispatch cycle has returned to the same state #{repeats}× " <>
      "(limit #{limit}) — #{gates}. State: #{fingerprint}"
  end

  # Human-readable on purpose: it's stored in plan metadata and quoted in the
  # needs_human message, where a hash would say nothing.
  defp plan_cycle_fingerprint(plan, identifier, pr_url) do
    rows =
      plan
      |> SymphonyElixir.Planning.Plan.rows()
      |> Enum.map(&"#{&1["id"]}=#{&1["state"]}")
      |> Enum.sort()
      |> Enum.join(",")

    verdict =
      case History.latest_tester_verdict(identifier) do
        %{verdict: v, commit_sha: sha} -> "#{v}@#{sha || "?"}"
        nil -> "untested"
      end

    rows <> " | " <> verdict <> " | " <> progress_marker(identifier, pr_url)
  end

  # BEFORE a PR exists the verdict and the PR head are both constants
  # (`untested`, `head=?`), so the fingerprint collapses to the row states alone
  # and a dispatch that closed a row and PUSHED looks identical to one that did
  # nothing (first Fly run, GEA-9889: R1 closed and 9ee9986b pushed, and the
  # breaker still counted three repeats). The evaluator records change totals on
  # every run, so use them as the pre-PR progress signal.
  defp progress_marker(_identifier, pr_url) when is_binary(pr_url) and pr_url != "" do
    "head=" <> pr_head_sha(pr_url)
  end

  defp progress_marker(identifier, _pr_url) when is_binary(identifier) do
    totals = History.issue_change_totals(identifier)
    "changed=#{totals.files_changed}f/#{totals.lines_changed}l"
  rescue
    _ -> "changed=?"
  end

  # The PR head belongs in the fingerprint: post-approval phases (Resolve
  # Review, Fix CI) change no row states and add no tester verdict — new
  # commits on the branch are the only progress signal, and without it the
  # breaker reads a converging CR-triage tail as stuck (false trip on
  # GEA-4662, 2026-07-15). "?" on any gh failure: an unreadable head must not
  # make every cycle look distinct, and "?" == "?" keeps the breaker armed.
  defp pr_head_sha(pr_url) when is_binary(pr_url) do
    case pr_ref(pr_url) do
      {repo, number} ->
        case gh_cmd(["pr", "view", number, "--repo", repo, "--json", "headRefOid", "-q", ".headRefOid"]) do
          {output, 0} -> output |> String.trim() |> String.slice(0, 12)
          _ -> "?"
        end

      :error ->
        "?"
    end
  rescue
    _ -> "?"
  end

  defp pr_head_sha(_), do: "?"

  defp verdict_reason_suffix(%{reason: reason}) when is_binary(reason) and reason != "",
    do: ": #{reason}"

  defp verdict_reason_suffix(_), do: ""

  # The plan's code rows are all done. A fresh @agent comment (the user
  # retasking after completion) takes priority over the tester gate: reopen the
  # rows and dispatch an Implement row-closer carrying the feedback. The feedback
  # rides in as each reopened row's rationale, which PromptBuilder renders into
  # the worker's prompt — so it works even though the comment predates the
  # redispatch (the mid-run @agent fetch would miss it). Otherwise, the tester
  # gate decides.
  # The reopen rationale that marks a dispatch as feedback-triggered; the marker
  # rides in as each reopened row's rationale, which lands in the dispatch's
  # assigned_rows_json — that is how last_feedback_dispatch_start recognizes
  # which dispatches actually carried the feedback.
  @agent_feedback_marker "Reviewer feedback via @agent"

  defp complete_plan_action(issue, metadata, plan) do
    case fresh_agent_feedback(issue, plan) do
      {:ok, feedback} ->
        Logger.info("Fresh @agent feedback on #{issue.identifier}; reopening rows to address it")
        reopen_and_dispatch(issue, metadata, plan, "#{@agent_feedback_marker} — address this: #{agent_feedback_snippet(feedback)}")

      :none ->
        # Actionable ship work comes BEFORE the tester gate: merge conflicts,
        # red CI, and requested-changes reviews need no browser walk, so a
        # missing or BLOCKED tester verdict must never wall them off (a tester
        # blocked on dead infra used to park the issue with CI failures and
        # CodeRabbit comments left unaddressed). :done still requires both —
        # the tester gate runs once the PR is externally clean.
        case external_ship_gate(metadata[:existing_pr_url]) do
          {:conflicts, reason} ->
            # Main moved under the PR. Same shape as Resolve Review:
            # rows stay done, the worker only rebases, resolves, and pushes.
            Logger.info("PR for #{issue.identifier} is conflicted; dispatching Resolve Conflicts: #{reason}")
            dispatch_review(issue, metadata, plan, reason, "Resolve Conflicts")

          {:ci, reason} ->
            # CI is red. Dispatch the dedicated Fix CI phase — its prompt
            # pulls the actual failing job logs and reproduces locally,
            # instead of a generic Implement row-closer that only sees the
            # failing check names and never learns what broke.
            Logger.info("CI is red for #{issue.identifier}; dispatching Fix CI: #{reason}")
            reopen_and_dispatch(issue, metadata, plan, reason, "Fix CI")

          {:request_changes, reason} ->
            # A reviewer (CodeRabbit or human) requested changes. Dispatch the
            # dedicated Resolve Review phase WITHOUT reopening the plan's rows:
            # the implementation is done — CR triage only addresses review
            # threads and re-checks the review gate. Reopening rows here would
            # send the issue back through Implement/Test and it would never
            # finish the CR pass.
            Logger.info("Review requested changes on #{issue.identifier}; dispatching Resolve Review: #{reason}")
            dispatch_review(issue, metadata, plan, reason)

          :ok ->
            complete_tester_action(issue, metadata, plan, metadata[:existing_pr_url])
        end
    end
  end

  # The PR is externally clean (no conflicts, CI green, no requested changes) —
  # the tester's verdict is the last gate before :done.
  defp complete_tester_action(issue, metadata, plan, pr_url) do
    case tester_gate(issue, plan, pr_url) do
      :approved ->
        :done

      :needs_test ->
        Logger.info("Plan code rows complete for #{issue.identifier}; dispatching the Test tester sub-agent")

        # Engage CodeRabbit now, in parallel with the tester, instead of only
        # after tester approval — its diff-aware review is a second net, and
        # getting its comments early means they're triaged (via the existing
        # review_gate → Resolve Review path) before the human gate rather than
        # serially after. The PR stays a draft; `@coderabbitai review` reviews
        # on request regardless. Once per PR head so we don't re-ping each poll.
        maybe_request_coderabbit_review(plan, pr_url)

        metadata =
          metadata
          |> Map.put(:retask_phases, ["Test"])
          |> Map.put(:model, Config.claude_test_model())

        {:dispatch, metadata}

      {:request_changes, reason} ->
        # The tester found gaps but can't edit code. Reopen the done rows and
        # dispatch an Implement row-closer; the Grader re-verifies on the next
        # completion, snapping untouched rows back to done.
        reopen_and_dispatch(issue, metadata, plan, reason)

      {:blocked, reason} ->
        # Tester BLOCKED: verification is impossible (infra down, missing
        # dependency) — a human has to unblock. Stop dispatching.
        {:blocked, {:tester_blocked, reason}}
    end
  end

  # Ask CodeRabbit to review the PR now (parallel to the tester), at most once
  # per PR head. Best-effort and off the orchestrator loop — a gh hiccup must
  # never stall dispatch. The head is stored in plan metadata so a re-poll at
  # the same head doesn't re-ping; a new commit (a Resolve Review/Fix CI push)
  # advances the head and re-requests, which is correct — CR should re-review.
  defp maybe_request_coderabbit_review(plan, pr_url) when is_binary(pr_url) and pr_url != "" do
    head = pr_head_sha(pr_url)
    already = get_in(plan.metadata || %{}, ["cr_review_head"])

    if head != "?" and head != already do
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        request_coderabbit_review(plan, pr_url, head)
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning("maybe_request_coderabbit_review failed: #{Exception.message(error)}")
      :ok
  end

  defp maybe_request_coderabbit_review(_, _), do: :ok

  defp request_coderabbit_review(plan, pr_url, head) do
    case System.cmd("gh", ["pr", "comment", pr_url, "--body", "@coderabbitai review"], stderr_to_stdout: true) do
      {_out, 0} ->
        Logger.info("Requested CodeRabbit review on #{pr_url} (head #{head}) in parallel with the tester")

        # Record only on success, against a fresh plan row, so a failed
        # request retries next poll and a concurrent metadata write isn't
        # clobbered.
        record_coderabbit_review_head(plan, head)

      {out, _} ->
        Logger.warning("Failed to request CodeRabbit review on #{pr_url}: #{String.trim(out)}")
    end
  end

  defp record_coderabbit_review_head(plan, head) do
    case SymphonyElixir.Repo.get(SymphonyElixir.Planning.Plan, plan.id) do
      %SymphonyElixir.Planning.Plan{} = fresh ->
        Planning.update_plan(fresh, %{
          metadata: Map.put(fresh.metadata || %{}, "cr_review_head", head)
        })

      _ ->
        :ok
    end
  end

  # The latest @agent comment, if no feedback-triggered Implement dispatch has
  # STARTED since it was posted. Only a dispatch this gate itself triggered
  # counts as handling the comment: an unrelated dispatch (Fix CI, a row-closer
  # already in flight when the comment landed) never carried the feedback in
  # its prompt, so neither its start nor its finish may mark the comment
  # handled. Returns {:ok, body} | :none. Best-effort: fetch errors → :none.
  defp fresh_agent_feedback(issue, plan) do
    case Client.fetch_issue_comments(Map.get(issue, :id)) do
      {:ok, comments} ->
        latest =
          comments
          |> Enum.filter(fn c -> c.created_at != nil and is_binary(c.body) and String.trim(c.body) != "" end)
          |> Enum.max_by(fn c -> DateTime.to_unix(c.created_at) end, fn -> nil end)

        last = last_feedback_dispatch_start(plan)

        cond do
          is_nil(latest) -> :none
          is_nil(last) -> {:ok, latest.body}
          DateTime.compare(latest.created_at, last) == :gt -> {:ok, latest.body}
          true -> :none
        end

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  defp agent_feedback_snippet(body) when is_binary(body) do
    body |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 600)
  end

  # Per-phase model: context-constrained phases run on the cheaper model; the
  # core Implement row-closer and anything unlisted stay on the default model.
  # (Test sets its own model at its dispatch site; Grade via the Grader.)
  defp model_for_phase("Fix CI"), do: Config.claude_fix_ci_model()
  defp model_for_phase(_phase), do: Config.claude_model()

  # Dispatch the Resolve Review (CR triage) phase WITHOUT reopening the plan's
  # rows. The implementation is done + tester-approved; this pass only addresses
  # review threads and re-checks the review gate on the next completion. No
  # Dispatch record is created, so the Grader does not run — nothing can flip the
  # done rows back open and bounce the issue into Implement/Test. The review gate
  # keeps re-dispatching this until the review approves.
  defp dispatch_review(issue, metadata, plan, reason, phase \\ "Resolve Review") do
    Logger.info("Dispatching #{phase} for #{issue.identifier} (#{reason}); rows left done")

    metadata =
      metadata
      |> Map.put(:retask_phases, [phase])
      |> Map.put(:plan_rows, SymphonyElixir.Planning.Plan.rows(plan))
      |> Map.put(:model, model_for_phase(phase))
      |> Map.delete(:plan_dispatch_id)
      |> Map.delete(:assigned_rows)

    {:dispatch, metadata}
  end

  # Record a Dispatch and build the metadata for an Implement row-closer dispatch.
  defp dispatch_implement(issue, metadata, plan, rows, why, phase \\ "Implement") do
    case PlanningWorkflow.start_implement_dispatch(plan, rows) do
      {:ok, dispatch} ->
        Logger.info("Dispatching #{phase} row-closer for #{issue.identifier} (#{why}, #{length(rows)} rows)")

        metadata =
          metadata
          |> Map.put(:retask_phases, [phase])
          |> Map.put(:assigned_rows, rows)
          |> Map.put(:plan_rows, SymphonyElixir.Planning.Plan.rows(plan))
          |> Map.put(:plan_dispatch_id, dispatch.id)
          |> Map.put(:model, model_for_phase(phase))

        {:dispatch, metadata}

      {:error, reason} ->
        {:blocked, {:dispatch_record_failed, reason}}
    end
  end

  # Reopen the plan's done rows and dispatch an Implement row-closer to address
  # `reason` (a tester REQUEST_CHANGES, a CI failure, or a requested-changes
  # review). The Grader re-verifies on the next completion, snapping untouched
  # rows back to done.
  defp reopen_and_dispatch(issue, metadata, plan, reason, phase \\ "Implement") do
    case reopen_done_rows(plan, reason) do
      {:ok, reopened} ->
        open = SymphonyElixir.Planning.Plan.open_rows(reopened)
        dispatch_implement(issue, metadata, reopened, open, reason, phase)

      {:error, err} ->
        {:blocked, {:reopen_rows_failed, err}}
    end
  end

  # The objective ship gate applied AFTER a tester APPROVE: an issue is only done
  # when CI is green and the PR carries no requested-changes review. The tester
  # validates behaviour but is blind to GitHub state, so without this a
  # tester-approved PR with a red build or a CHANGES_REQUESTED review would be
  # marked done. Returns :ok | {:request_changes, reason}.
  #
  # Inability to evaluate (no PR yet, gh failure) returns :ok rather than
  # blocking: a transient gh error must never wedge a finished issue, and the
  # continuation cap bounds any retry. PENDING checks are not treated as a
  # failure (only explicit failure states are) — the tester runs far longer than
  # CI, so checks are effectively always resolved by the time the gate runs.
  defp external_ship_gate(pr_url) do
    with :ok <- merge_gate(pr_url),
         :ok <- ci_gate(pr_url) do
      review_gate(pr_url)
    end
  end

  # Conflicts first: a conflicted PR must rebase before CI/review state means
  # anything, and main moving under a parked PR is how "done" issues silently
  # become unmergeable.
  defp merge_gate(pr_url) do
    if pr_conflicting?(pr_url) do
      {:conflicts, "PR has merge conflicts with its base branch — rebase and resolve"}
    else
      :ok
    end
  end

  @gh_timeout_ms 30_000

  defp ci_gate(pr_url) do
    case pr_ref(pr_url) do
      {repo, number} ->
        {output, _status} = gh_cmd(["pr", "checks", number, "--repo", repo, "--json", "name,state"])

        case failed_checks(output) do
          [] -> :ok
          names -> {:ci, "CI checks failing: #{Enum.join(names, ", ")}"}
        end

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # System.cmd/3 has no timeout; bound the gh call with a Task so a stalled gh
  # never wedges dispatch. Timeout returns a non-zero sentinel, which the gates
  # treat as "can't verify" → :ok (fail-safe, never blocks a finished issue).
  defp gh_cmd(args) do
    task = Task.async(fn -> System.cmd("gh", args, stderr_to_stdout: true) end)

    case Task.yield(task, @gh_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {output, status}
      _ -> {"", 124}
    end
  end

  @failing_check_states ~w(FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE)

  defp failed_checks(output) do
    case Jason.decode(output) do
      {:ok, checks} when is_list(checks) ->
        checks
        |> Enum.filter(fn c -> Map.get(c, "state") in @failing_check_states end)
        |> Enum.map(fn c -> Map.get(c, "name", "check") end)

      _ ->
        []
    end
  end

  defp review_gate(pr_url) do
    case pr_ref(pr_url) do
      {repo, number} ->
        pr_review_gate(repo, number)

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp pr_review_gate(repo, number) do
    case gh_cmd(["pr", "view", number, "--repo", repo, "--json", "reviewDecision,latestReviews"]) do
      {output, 0} ->
        output
        |> Jason.decode()
        |> review_decision_gate(repo, number)

      _ ->
        :ok
    end
  end

  defp review_decision_gate({:ok, %{"reviewDecision" => "CHANGES_REQUESTED"}}, _repo, _number) do
    {:request_changes, "PR review requested changes"}
  end

  # CodeRabbit runs in request-changes mode and is a hard merge gate,
  # but it is not always a "required" reviewer, so reviewDecision can
  # be nil while CodeRabbit's own review still sits at CHANGES_REQUESTED.
  # Block on its review directly; the worker clears it by resolving the
  # comments and posting `@coderabbitai resolve` (auto-approves on green CI).
  defp review_decision_gate({:ok, decoded}, repo, number) do
    cond do
      coderabbit_requested_changes?(decoded) ->
        {:request_changes, "CodeRabbit requested changes — resolve its comments and post `@coderabbitai resolve`"}

      # A later CodeRabbit round can land as a COMMENTED review with
      # unresolved threads and an empty reviewDecision — invisible to
      # both checks above, so the issue completed with open Major
      # comments (GEA-5242). Unresolved threads block the same way.
      (n = unresolved_review_threads(repo, number)) > 0 ->
        {:request_changes, "#{n} unresolved review threads — address them and post `@coderabbitai resolve`"}

      true ->
        :ok
    end
  end

  defp review_decision_gate(_decoded, _repo, _number), do: :ok

  # Count of unresolved PR review threads. Fail-safe like the other gates: any
  # gh/parse failure counts as 0 so a transient error never wedges a finished
  # issue.
  defp unresolved_review_threads(repo, number) do
    [owner, name] = String.split(repo, "/", parts: 2)

    query =
      "query { repository(owner:\"#{owner}\", name:\"#{name}\") { pullRequest(number:#{number}) { reviewThreads(first:100) { nodes { isResolved } } } } }"

    jq = "[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length"

    case gh_cmd(["api", "graphql", "-f", "query=#{query}", "--jq", jq]) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {n, _} -> n
          :error -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp coderabbit_requested_changes?(%{"latestReviews" => reviews}) when is_list(reviews) do
    Enum.any?(reviews, fn review ->
      login = get_in(review, ["author", "login"])

      is_binary(login) and String.starts_with?(login, "coderabbit") and
        Map.get(review, "state") == "CHANGES_REQUESTED"
    end)
  end

  defp coderabbit_requested_changes?(_), do: false

  defp pr_ref(pr_url) when is_binary(pr_url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, pr_url) do
      [_, repo, number] -> {repo, number}
      _ -> :error
    end
  end

  defp pr_ref(_), do: :error

  # Decide what the tester says about the current (code-complete) plan:
  #   :needs_test            — no tester report yet, or the latest one predates
  #                            the last Implement dispatch (code changed since).
  #   {:request_changes, _}  — fresh report that isn't a clean APPROVE.
  #   :approved              — fresh report that cleanly approves.
  # On a Linear fetch failure we return :needs_test so the tester runs again
  # rather than declaring the issue done on missing evidence; the continuation
  # cap bounds any loop.
  # The tester verdict lives in the DB (recorded from the tester's
  # SYMPHONY_VERDICT marker) — the machine source of truth. A verdict older than
  # the last Implement dispatch is stale (code changed since), so re-test. Fall
  # back to parsing the Linear report only when there is no DB verdict yet
  # (legacy / in-flight issues), so we don't force a needless re-test on rollout.
  defp tester_gate(issue, plan, pr_url) do
    last_implement = last_implement_dispatch_finish(plan)

    case History.latest_tester_verdict(Map.get(issue, :identifier)) do
      %SymphonyElixir.History.TesterVerdict{} = verdict ->
        cond do
          stale_verdict?(verdict, last_implement) and not verdict_at_head?(verdict, pr_url) ->
            :needs_test

          verdict.verdict == "APPROVE" ->
            :approved

          verdict.verdict == "BLOCKED" ->
            # BLOCKED means the tester couldn't verify for reasons no Implement
            # worker can fix (infra down, missing dependency). Reopening rows
            # here just grinds no-progress Implement dispatches forever.
            {:blocked, "tester BLOCKED at #{DateTime.to_iso8601(verdict.inserted_at)}#{verdict_reason_suffix(verdict)}"}

          true ->
            # The reason rides into the reopened rows' rationale and from there
            # into the next worker's prompt — without it each Implement pass
            # re-guesses what the tester objected to (the GEA-4625 churn).
            {:request_changes, "tester #{verdict.verdict} at #{DateTime.to_iso8601(verdict.inserted_at)}#{verdict_reason_suffix(verdict)}"}
        end

      nil ->
        tester_gate_from_linear(issue, last_implement)
    end
  rescue
    _ -> :needs_test
  end

  defp stale_verdict?(%{inserted_at: at}, last_implement) do
    not is_nil(last_implement) and DateTime.compare(at, last_implement) != :gt
  end

  # A verdict at the PR's current head is fresh no matter when it was recorded:
  # a later dispatch that pushed nothing (a no-op Fix CI rerun) must not
  # invalidate an APPROVE for the same code (GEA-5113/GEA-5115 tester loop).
  defp verdict_at_head?(%{commit_sha: sha}, pr_url) when is_binary(sha) and sha != "" do
    head = pr_head_sha(pr_url)
    head != "?" and String.starts_with?(sha, head)
  end

  defp verdict_at_head?(_, _), do: false

  defp tester_gate_from_linear(issue, last_implement) do
    case Client.fetch_all_issue_comments(Map.get(issue, :id)) do
      {:ok, comments} ->
        latest = latest_tester_report(comments)

        cond do
          is_nil(latest) ->
            :needs_test

          not is_nil(last_implement) and DateTime.compare(latest.created_at, last_implement) != :gt ->
            :needs_test

          request_changes?(latest.body) ->
            {:request_changes, "tester REQUEST_CHANGES at #{DateTime.to_iso8601(latest.created_at)}"}

          true ->
            :approved
        end

      _ ->
        :needs_test
    end
  end

  # Plan generation/advancement failed and there is no phase-judge fallback.
  # Notify a human, move the issue to the configured review state, and stop
  # dispatching it. A human re-activating the issue re-enters the loop fresh.
  defp block_issue_for_plan_failure(%State{} = state, issue, reason) do
    if transient_plan_failure?(reason) do
      # A transient session-startup failure — usually the planner's tmux
      # OneShot timing out before it signals ready. The poller re-dispatches
      # active issues, so this self-recovers on a later attempt (observed:
      # two ready_timeouts then success). Don't escalate to a human or post a
      # needs_human comment for a blip the retry path fixes; just log and let
      # the next poll try again.
      Logger.warning("Plan workflow hit a transient failure for #{issue_context(issue)}: #{inspect(reason)}; retrying on next poll")
      complete_issue(state, issue.id)
    else
      Logger.error("Plan workflow blocked for #{issue_context(issue)}: #{inspect(reason)}; notifying human")

      message = "Symphony could not produce or advance a plan: #{inspect(reason)}"

      Notifier.notify(:needs_human, %{
        issue_id: issue.id,
        identifier: issue.identifier,
        help_message: message
      })

      move_blocked_issue_to_needs_human_state(issue, Config.escalation_needs_human_state())

      # A PARKED ISSUE STILL OWES A PR. It gets no more dispatches, so whatever
      # the worker pushed is all there will ever be — and a person (or the
      # harness) judges from a PR, never from a bare branch. GEA-9699 was parked
      # with commit `9ee9986b` pushed and no PR, which is the case this closes
      # (GEA-9888, the machine owner's rule of 2026-09-22). Opening it costs
      # nothing when the branch has one already.
      ensure_pr_for_issue(issue)
      clear_working_label(issue.id, issue.identifier)

      # Sticky: `completed` issues are re-assessed every poll, which for a
      # blocked issue meant re-blocking — and re-posting the needs-human
      # comment — every ~2.5 minutes (observed on GEA-4478).
      state = %{state | blocked: MapSet.put(state.blocked, issue.id)}
      complete_issue(state, issue.id)
    end
  end

  defp move_blocked_issue_to_needs_human_state(issue, needs_human_state) when is_binary(needs_human_state) do
    case Tracker.update_issue_state(issue.id, needs_human_state) do
      :ok -> Logger.info("Moved blocked issue #{issue.identifier} to state '#{needs_human_state}'")
      {:error, reason} -> Logger.warning("Failed to move blocked issue #{issue.identifier}: #{inspect(reason)}")
    end
  end

  defp move_blocked_issue_to_needs_human_state(_issue, _needs_human_state), do: :ok

  # Transient plan-generation failures are session-startup blips (the planner's
  # tmux OneShot not becoming ready in time), not genuine "needs a human"
  # blocks. The poller retries active issues, so these recover on their own.
  defp transient_plan_failure?({:plan_assess_failed, {:start_session_failed, _}}), do: true
  defp transient_plan_failure?({:start_session_failed, _}), do: true
  defp transient_plan_failure?(_), do: false

  defp latest_tester_report(comments) do
    comments
    |> Enum.filter(fn c ->
      is_binary(c.body) and String.contains?(c.body, "## Tester Report") and c.created_at != nil
    end)
    |> Enum.max_by(fn c -> DateTime.to_unix(c.created_at) end, fn -> nil end)
  end

  # A Tester Report is "request_changes-like" if it does NOT cleanly approve.
  # Tester sub-agents in practice emit non-canonical strings like
  # `Recommendation: 🚫 BLOCK`, `Recommendation: ⚠ APPROVE-AFTER-PUSH`, or
  # `Recommendation: REQUEST_CHANGES`. Treat anything that isn't a strict
  # `Recommendation: APPROVE` (with no `-AFTER-` / `-WITH-` qualifier) as
  # "needs more work."
  defp request_changes?(body) when is_binary(body) do
    not strict_tester_approve?(body)
  end

  defp request_changes?(_), do: false

  # Strict approve: `Recommendation: APPROVE` followed by end-of-line or
  # whitespace, with no qualifier like `APPROVE-AFTER-PUSH`. Tolerates markdown
  # bolding anywhere around the label, colon, or value — testers write any of
  # `Recommendation: APPROVE`, `**Recommendation:** APPROVE`,
  # `**Recommendation**: APPROVE`, `Recommendation: **APPROVE**`. (Matching only
  # the unbolded `Recommendation:` made every bolded-label approve read as
  # request-changes, looping Test forever.)
  defp strict_tester_approve?(body) when is_binary(body) do
    Regex.match?(
      ~r/\*{0,2}Recommendation\*{0,2}:\*{0,2}\s*\*{0,2}APPROVE(?=\s|\*|$|\.)/m,
      body
    ) and
      not Regex.match?(
        ~r/\*{0,2}Recommendation\*{0,2}:[^\n]*APPROVE[-\s]+(?:AFTER|WITH|PENDING|SUBJECT|ONCE|IF|MODULO)/i,
        body
      )
  end

  defp strict_tester_approve?(_), do: false

  defp last_implement_dispatch_finish(%SymphonyElixir.Planning.Plan{id: plan_id}) do
    SymphonyElixir.Planning.dispatches_for_plan(plan_id)
    |> Enum.filter(fn d -> d.role == "implement" and d.finished_at != nil end)
    |> Enum.max_by(fn d -> DateTime.to_unix(d.finished_at) end, fn -> nil end)
    |> then(fn
      nil -> nil
      d -> d.finished_at
    end)
  end

  # When the last feedback-triggered Implement dispatch STARTED (start, not
  # finish: a comment posted mid-run would finish "behind" finished_at and look
  # handled without ever reaching a prompt). Feedback-triggered = the reopen
  # rationale marker is in the dispatch's assigned rows.
  defp last_feedback_dispatch_start(%SymphonyElixir.Planning.Plan{id: plan_id}) do
    SymphonyElixir.Planning.dispatches_for_plan(plan_id)
    |> Enum.filter(fn d ->
      d.role == "implement" and d.started_at != nil and feedback_dispatch?(d)
    end)
    |> Enum.max_by(fn d -> DateTime.to_unix(d.started_at) end, fn -> nil end)
    |> then(fn
      nil -> nil
      d -> d.started_at
    end)
  end

  defp feedback_dispatch?(dispatch) do
    (dispatch.assigned_rows_json || %{})
    |> Map.get("rows", [])
    |> Enum.any?(fn row ->
      String.contains?(Map.get(row, "rationale") || "", @agent_feedback_marker)
    end)
  end

  # Flip every `done` row back to `partial` with a rationale, persist, return
  # the updated plan. Deferred and partial/missing rows are left alone.
  defp reopen_done_rows(%SymphonyElixir.Planning.Plan{} = plan, rationale) do
    new_rows =
      plan
      |> SymphonyElixir.Planning.Plan.rows()
      |> Enum.map(fn row ->
        case row["state"] do
          "done" ->
            row
            |> Map.put("state", "partial")
            |> Map.put("rationale", rationale)

          _ ->
            row
        end
      end)

    SymphonyElixir.Planning.replace_rows(plan, new_rows)
  end

  # After a plan-driven worker dispatch finishes, grade its diff against the
  # rows it was assigned. Updates the plan in SQLite; the refreshed row states
  # feed the NEXT call to `plan_action/2`, which decides whether to re-dispatch
  # the still-open rows, run the tester, finish, or block.
  defp maybe_grade_plan_dispatch(running_entry) do
    case running_entry[:plan_dispatch_id] do
      nil ->
        :ok

      dispatch_id when is_binary(dispatch_id) ->
        grade_plan_dispatch(running_entry, dispatch_id)
    end
  rescue
    error ->
      Logger.error("maybe_grade_plan_dispatch crashed: #{Exception.message(error)}")
      :ok
  end

  defp grade_plan_dispatch(running_entry, dispatch_id) do
    with %SymphonyElixir.Planning.Dispatch{} = dispatch <-
           SymphonyElixir.Repo.get(SymphonyElixir.Planning.Dispatch, dispatch_id),
         %SymphonyElixir.Planning.Plan{} = plan <-
           SymphonyElixir.Repo.get(SymphonyElixir.Planning.Plan, dispatch.plan_id),
         {:ok, diff} <- fetch_dispatch_diff(running_entry) do
      # External evidence: PR description. Worker can edit it via
      # `gh pr edit --body`, but it's not in `git diff`. Without this
      # the Grader can never verify "update PR description" rows.
      pr_body = fetch_pr_body(running_entry)

      # Code-context evidence: the change census re-derives, from the diff,
      # which lib/ callers of changed functions the diff did NOT touch — the
      # "signature changed, did every caller follow?" gap the stat-only diff
      # can't show. Un-blinds the grader on the #1 defect class.
      census = fetch_dispatch_census(running_entry)

      case PlanningWorkflow.grade_dispatch(dispatch,
             plan: plan,
             diff: diff,
             test_output: "",
             pr_body: pr_body,
             census: census
           ) do
        {:ok, {verdict, _updated_plan}} ->
          Logger.info("Grader verdict for plan dispatch=#{dispatch_id} verdict=#{verdict} issue=#{running_entry[:identifier]}")

          :ok

        {:error, reason} ->
          Logger.warning("Grader failed for plan dispatch=#{dispatch_id} reason=#{inspect(reason)}")

          :ok
      end
    else
      nil ->
        Logger.warning("Grader skipped: plan dispatch=#{dispatch_id} not found")
        :ok

      {:error, reason} ->
        Logger.warning("Grader skipped: #{inspect(reason)}")
        :ok
    end
  end

  # Read the working-directory diff from the slot so the Grader has evidence.
  # Falls back to an empty diff if anything goes wrong — the Grader will then
  # see "no changes" and mark every assigned row missing, which is the right
  # answer for a dispatch that failed to push code.
  # Resolve the slot working-copy directory for a running dispatch by reading
  # DIRECTORY= out of the workspace's `.symphony_slot` file. nil if unresolvable.
  defp dispatch_slot_dir(running_entry) do
    with identifier when is_binary(identifier) <- running_entry[:identifier],
         workspace = Path.join(SymphonyElixir.Config.workspace_root(), identifier),
         slot_file = Path.join(workspace, ".symphony_slot"),
         {:ok, content} <- File.read(slot_file),
         [_, dir] <- Regex.run(~r/DIRECTORY=(.+)/, content) do
      String.trim(dir)
    else
      _ -> nil
    end
  end

  # Run the change census in the dispatch's slot: which lib/ callers of the
  # functions this branch changed live in files the diff didn't touch. Best
  # effort — empty string on any failure so the grader just loses this evidence
  # channel rather than the grade crashing.
  defp fetch_dispatch_census(running_entry) do
    slot_dir = dispatch_slot_dir(running_entry)
    script = Path.join(:code.priv_dir(:symphony_elixir), "scripts/change-census.sh")

    if slot_dir && File.dir?(slot_dir) && File.exists?(script) do
      base = read_base_branch(slot_dir)

      case System.cmd("bash", [script, base], cd: slot_dir, stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> ""
      end
    else
      ""
    end
  rescue
    error ->
      Logger.warning("fetch_dispatch_census failed: #{Exception.message(error)}")
      ""
  end

  defp fetch_dispatch_diff(running_entry) do
    workspace_path = dispatch_slot_dir(running_entry)

    if workspace_path && File.dir?(workspace_path) do
      base = read_base_branch(workspace_path)

      # Don't dump the full diff text — for branches with hundreds of commits
      # it dwarfs the LLM's context and gets truncated, hiding the very files
      # the Grader is trying to verify. Give a structured summary instead:
      # file list + line counts + commit subjects. The Grader can match
      # files against row.touches and commit subjects against row.id from
      # this without seeing every changed line.
      cmd = """
      git fetch origin #{base} >/dev/null 2>&1
      echo "=== diff base: origin/#{base} ==="
      echo "=== files changed (git diff --stat) ==="
      git diff --stat "origin/#{base}..HEAD"
      echo
      echo "=== commits on branch (git log --oneline) ==="
      git log --oneline "origin/#{base}..HEAD" | head -200
      echo
      echo "=== file list with status (git diff --name-status) ==="
      git diff --name-status "origin/#{base}..HEAD"
      """

      case System.cmd("sh", ["-c", cmd], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {_, _} -> {:ok, ""}
      end
    else
      {:ok, ""}
    end
  end

  # External-evidence fetcher: pull the current PR description for the issue's
  # open PR, so the Grader can verify rows whose deliverable lives in PR-body
  # markdown rather than in the git tree.
  defp fetch_pr_body(running_entry) do
    workspace_path =
      with identifier when is_binary(identifier) <- running_entry[:identifier],
           workspace = Path.join(SymphonyElixir.Config.workspace_root(), identifier),
           slot_file = Path.join(workspace, ".symphony_slot"),
           {:ok, content} <- File.read(slot_file),
           [_, dir] <- Regex.run(~r/DIRECTORY=(.+)/, content) do
        String.trim(dir)
      else
        _ -> nil
      end

    cond do
      not is_binary(running_entry[:identifier]) ->
        nil

      workspace_path == nil or not File.dir?(workspace_path) ->
        nil

      true ->
        open_pr_json(running_entry[:identifier], workspace_path)
    end
  rescue
    _ -> nil
  end

  defp open_pr_json(identifier, workspace_path) do
    # `gh pr list --search "<id>"` is repo-scoped via the slot's git remote.
    cmd =
      ~s|gh pr list --search "#{identifier}" --state open --json number,url,body,title --jq '.[0]'|

    case System.cmd("sh", ["-c", cmd], cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} ->
        trimmed = String.trim(output)
        if trimmed in ["", "null"], do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp read_base_branch(workspace_path) do
    # BASE_BRANCH lives in .symphony_slot (written by slot-claim.sh), NOT
    # .env.symphony (which only has port assignments).
    slot_file = Path.join(workspace_path, ".symphony_slot")

    case File.read(slot_file) do
      {:ok, content} ->
        case Regex.run(~r/BASE_BRANCH=(\S+)/, content) do
          [_, base] -> String.trim(base)
          _ -> "main"
        end

      _ ->
        "main"
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1

    # Enforce max failure retries (does not apply to continuations)
    if metadata[:delay_type] != :continuation and next_attempt > Config.max_failure_retries() do
      exhaust_failure_retries(state, issue_id, previous_retry, next_attempt, metadata)
    else
      do_schedule_issue_retry(state, issue_id, next_attempt, previous_retry, metadata)
    end
  end

  defp exhaust_failure_retries(state, issue_id, previous_retry, next_attempt, metadata) do
    identifier = metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id

    Logger.warning("Max failure retries (#{Config.max_failure_retries()}) exhausted for issue_id=#{issue_id} issue_identifier=#{identifier}; stopping")

    Notifier.notify(:max_failure_retries_exhausted, %{
      issue_id: issue_id,
      identifier: identifier,
      attempt: next_attempt,
      max_retries: Config.max_failure_retries()
    })

    clear_working_label(issue_id, identifier)
    state = complete_issue(state, issue_id)
    record_max_retries_event(state, issue_id, identifier, next_attempt)
    state
  end

  defp do_schedule_issue_retry(%State{} = state, issue_id, next_attempt, previous_retry, metadata) do
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            continuation_count: Map.get(metadata, :continuation_count, 0),
            retask_phases: Map.get(metadata, :retask_phases),
            completed_phases: Map.get(metadata, :completed_phases)
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          continuation_count: Map.get(retry_entry, :continuation_count, 0),
          retask_phases: Map.get(retry_entry, :retask_phases),
          completed_phases: Map.get(retry_entry, :completed_phases)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  # Remove the workspace this run RECORDED at dispatch. Recomputing it from the
  # live config sends the removal at whatever `workspace.root` says now — a
  # reload between dispatch and cleanup then leaves the real workspace behind,
  # still holding its pool slot (upstream 7cf29df).
  defp cleanup_issue_workspace(running_entry, identifier) when is_map(running_entry) do
    case Map.get(running_entry, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        case Workspace.remove_recorded(workspace_path) do
          {:error, reason, _output} ->
            # Swallowing this leaves the workspace in place AND its pool slot
            # claimed, with nothing said. Fall back to the identifier so the
            # slot is still released.
            Logger.warning("Recorded workspace removal failed path=#{workspace_path} reason=#{inspect(reason)}; falling back to the identifier")

            cleanup_issue_workspace(identifier)

          _removed ->
            :ok
        end

      _ ->
        cleanup_issue_workspace(identifier)
    end
  end

  defp kill_running_hook(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        case Workspace.kill_hook_tree(workspace_path) do
          [] -> :ok
          pids -> Logger.info("Killed abandoned workspace hook process tree workspace=#{workspace_path} pids=#{inspect(pids)}")
        end

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to kill workspace hook process tree: #{Exception.message(error)}")
      :ok
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      # The retry poll's read and the dispatch-time revalidation are two reads,
      # and the second one decides. Act on its outcome rather than discarding it:
      # `dispatch_issue/4` answers `state` for all three non-ok outcomes, which
      # here would leave the issue claimed and no longer in the retry queue.
      case refresh_issue_for_dispatch(issue) do
        {:ok, %Issue{} = refreshed_issue} ->
          {:noreply, dispatch_refreshed_issue(state, refreshed_issue, attempt, metadata)}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :no_capacity ->
        # Waiting for a pool slot to free — a steady gentle poll, not a failure.
        @no_capacity_retry_delay_ms

      :continuation ->
        # Exponential backoff: 30s, 60s, 120s, 240s, ...
        min(@continuation_retry_delay_ms * (1 <<< (attempt - 1)), Config.max_retry_backoff_ms())

      _ ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  # Between the dispatch line and the run's end line, this is the only thing a
  # reader of `fly logs` learns about where an agent has got to — the board used
  # to carry it and nothing else did (GEA-10144).
  defp log_phase_change(running_entry, old_phase, phase) do
    Logger.info(
      "Phase change: #{issue_context(running_entry.issue)} session_id=#{running_entry.session_id} " <>
        "#{old_phase || "none"} -> #{phase}"
    )
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> cached_snapshot() || :timeout
        :exit, _ -> cached_snapshot() || :unavailable
      end
    else
      :unavailable
    end
  end

  defp ensure_snapshot_cache do
    :ets.whereis(@snapshot_cache) != :undefined or
      :ets.new(@snapshot_cache, [:named_table, :public, :set, read_concurrency: true])

    :ok
  end

  defp cache_snapshot(payload) do
    if :ets.whereis(@snapshot_cache) != :undefined do
      :ets.insert(@snapshot_cache, {:last, payload, System.monotonic_time(:millisecond)})
    end

    payload
  end

  # Last-known snapshot, tagged with how stale it is, or nil if none cached yet.
  defp cached_snapshot do
    case :ets.whereis(@snapshot_cache) != :undefined && :ets.lookup(@snapshot_cache, :last) do
      [{:last, payload, cached_ms}] ->
        Map.put(payload, :stale_age_ms, System.monotonic_time(:millisecond) - cached_ms)

      _ ->
        nil
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          cumulative_input_tokens: Map.get(metadata, :prior_issue_input_tokens, 0) + metadata.codex_input_tokens,
          cumulative_output_tokens: Map.get(metadata, :prior_issue_output_tokens, 0) + metadata.codex_output_tokens,
          cumulative_total_tokens: Map.get(metadata, :prior_issue_total_tokens, 0) + metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          phase: Map.get(metadata, :phase),
          phases_seen: Map.get(metadata, :phases_seen, []),
          phase_changed_at: Map.get(metadata, :phase_changed_at),
          pr_url: Map.get(metadata, :pr_url),
          screenshot_urls: Map.get(metadata, :screenshot_urls, []),
          history_run_id: Map.get(metadata, :history_run_id),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    payload = %{
      running: running,
      retrying: retrying,
      completed_history: state.completed_history,
      codex_totals: state.codex_totals,
      rate_limits: Map.get(state, :codex_rate_limits),
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms
      }
    }

    {:reply, cache_snapshot(payload), state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:stop_issue, issue_id}, _from, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      running_entry ->
        Logger.warning("Stopping issue via dashboard action: issue_id=#{issue_id} issue_identifier=#{running_entry.identifier}")

        state =
          state
          |> terminate_running_issue(issue_id, false, :dashboard_stopped)
          |> complete_issue(issue_id)

        notify_dashboard()
        {:reply, :ok, state}
    end
  end

  def handle_call({:retry_issue_manual, issue_id}, _from, state) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        {:reply, :ok, do_force_dispatch(state, issue)}

      {:ok, []} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:force_dispatch_identifier, identifier}, _from, state) do
    normalized = identifier |> to_string() |> String.trim() |> String.upcase()

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.identifier == normalized)) do
          %Issue{} = issue ->
            {:reply, :ok, do_force_dispatch(state, issue)}

          nil ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_retry, issue_id}, _from, state) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{timer_ref: timer_ref} ->
        if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

        Logger.info("Cancelled retry via dashboard action: issue_id=#{issue_id}")

        state = %{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id)
        }

        notify_dashboard()
        {:reply, :ok, state}
    end
  end

  defp do_force_dispatch(state, %Issue{} = issue) do
    Logger.info("Manual force dispatch: #{issue_context(issue)}")

    # Release any lingering pool slot so the fresh dispatch can claim one
    Task.start(fn -> Workspace.release_pool_slot_for_issue(issue.identifier) end)

    # Clear this issue's run history so the forced re-dispatch starts clean
    History.delete_all_runs(issue.identifier)

    # Clear in-memory tracking so should_dispatch_issue? passes. Includes the
    # sticky `blocked` set: a human forcing a dispatch IS the unblock — without
    # this, the poller skips the issue again after the forced run completes and
    # every subsequent phase needs another manual force (or a restart).
    state = %{
      state
      | completed: MapSet.delete(state.completed, issue.id),
        claimed: MapSet.delete(state.claimed, issue.id),
        blocked: MapSet.delete(state.blocked, issue.id)
    }

    state = dispatch_issue(state, issue)
    notify_dashboard()
    state
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    # Detect phase and PR URL from agent messages (sticky — only updates when found)
    old_phase = Map.get(running_entry, :phase)
    phase = phase_for_update(running_entry, update)
    pr_url = pr_url_for_update(running_entry, update)
    _old_pr_url = Map.get(running_entry, :pr_url)

    # Track screenshot URLs from Playwright tool uses
    screenshot_urls = screenshot_urls_for_update(running_entry, update)

    # Update phase_changed_at and phases_seen when phase transitions
    existing_phases = Map.get(running_entry, :phases_seen, [])

    {phase_changed_at, phases_seen} =
      if phase != old_phase and phase != nil do
        log_phase_change(running_entry, old_phase, phase)

        updated_phases =
          if phase in existing_phases, do: existing_phases, else: existing_phases ++ [phase]

        {timestamp, updated_phases}
      else
        {Map.get(running_entry, :phase_changed_at, timestamp), existing_phases}
      end

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        phase: phase,
        phase_changed_at: phase_changed_at,
        phases_seen: phases_seen,
        pr_url: pr_url,
        screenshot_urls: screenshot_urls,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp phase_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    case StreamParser.extract_phase(raw) do
      nil -> Map.get(running_entry, :phase)
      phase -> phase
    end
  end

  defp phase_for_update(running_entry, _update), do: Map.get(running_entry, :phase)

  defp pr_url_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    case StreamParser.extract_pr_url(raw) do
      nil -> Map.get(running_entry, :pr_url)
      url -> url
    end
  end

  defp pr_url_for_update(running_entry, _update), do: Map.get(running_entry, :pr_url)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  # Interactive Claude (tmux) runs one persistent session, so there is no per-turn
  # `:session_started`. Claude.AgentRunner instead emits a `:turn_completed` update
  # carrying the turn number; trust it directly.
  defp turn_count_for_update(_existing_count, _existing_session_id, %{
         event: :turn_completed,
         turn: turn
       })
       when is_integer(turn),
       do: turn

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  # Persist the running token/turn/phase totals to the run row, throttled, so the
  # DB reflects an in-flight run (single long turns otherwise only persist at
  # completion) and the figures survive a restart. Returns the entry with an
  # updated persist watermark.
  @progress_persist_interval_ms 15_000
  defp maybe_persist_run_progress(running_entry) do
    run_id = Map.get(running_entry, :history_run_id)
    last = Map.get(running_entry, :last_progress_persist_at)
    now = System.monotonic_time(:millisecond)

    if is_binary(run_id) and (last == nil or now - last >= @progress_persist_interval_ms) do
      case History.update_progress(run_id, %{
             input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
             output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
             total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
             turns_used: Map.get(running_entry, :turn_count, 0),
             final_phase: Map.get(running_entry, :phase)
           }) do
        {:ok, _run} ->
          # Only mark progress persisted on success, so a failed checkpoint isn't
          # throttled away — the next tick retries it.
          Map.put(running_entry, :last_progress_persist_at, now)

        {:error, reason} ->
          Logger.warning("Failed to persist run progress: #{inspect(reason)}")
          running_entry
      end
    else
      running_entry
    end
  rescue
    error ->
      Logger.warning("Failed to persist run progress: #{Exception.message(error)}")
      running_entry
  end

  defp record_completed_history(%State{} = state, running_entry, reason)
       when is_map(running_entry) do
    now = DateTime.utc_now()

    outcome =
      case reason do
        :normal -> "completed"
        {:terminated, _} -> "terminated"
        _ -> "failed"
      end

    error =
      case reason do
        :normal -> nil
        {%RuntimeError{message: msg}, _} -> msg
        other -> inspect(other)
      end

    summary = %{
      issue_id: running_entry[:identifier] || "unknown",
      issue_identifier: running_entry[:identifier],
      started_at: running_entry[:started_at],
      completed_at: now,
      phase: Map.get(running_entry, :phase),
      phases_seen: Map.get(running_entry, :phases_seen, []),
      pr_url: Map.get(running_entry, :pr_url),
      outcome: outcome,
      error: error,
      last_event: Map.get(running_entry, :last_codex_event),
      last_message: Map.get(running_entry, :last_codex_message),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: %{
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0)
      }
    }

    eval_result = record_completion_to_history(running_entry, outcome, reason, now)

    {%{state | completed_history: [summary | state.completed_history]}, eval_result}
  end

  defp record_completed_history(state, _running_entry, _reason), do: {state, nil}

  defp record_dispatch_to_history(issue, attempt, now) do
    attrs = %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      issue_priority: issue.priority,
      issue_labels: issue.labels || [],
      filter_source: "filter",
      started_at: now,
      agent_backend: Config.agent_backend(),
      retry_attempt: normalize_retry_attempt(attempt) || 0
    }

    case History.record_dispatch(attrs) do
      {:ok, run} ->
        run.id

      {:error, reason} ->
        Logger.warning("Failed to record dispatch to history: #{inspect(reason)}")
        nil
    end
  end

  defp record_completion_to_history(running_entry, outcome, reason, now) do
    run_id = Map.get(running_entry, :history_run_id)

    if run_id do
      started_at = Map.get(running_entry, :started_at)

      wall_clock_ms =
        if started_at do
          DateTime.diff(now, started_at, :millisecond)
        end

      error_info = categorize_error(reason)

      attrs = %{
        finished_at: now,
        outcome: outcome,
        session_id: Map.get(running_entry, :session_id),
        turns_used: Map.get(running_entry, :turn_count, 0),
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
        wall_clock_ms: wall_clock_ms,
        final_phase: Map.get(running_entry, :phase),
        error_message: error_info[:message],
        error_category: error_info[:category]
      }

      # Record completion, then run evaluation
      case History.record_completion(run_id, attrs) do
        {:ok, _run} ->
          run_evaluation(running_entry, run_id)

        {:error, reason} ->
          Logger.warning("Failed to record completion to history: #{inspect(reason)}")
          nil
      end
    end
  rescue
    error ->
      Logger.warning("Failed to record completion to history: #{Exception.message(error)}")
  end

  defp run_evaluation(running_entry, run_id) do
    run_context = %{
      issue_id: Map.get(running_entry, :issue, %{}) |> Map.get(:id),
      branch_name: Map.get(running_entry, :issue, %{}) |> Map.get(:branch_name),
      identifier: Map.get(running_entry, :identifier)
    }

    identifier = running_entry[:identifier]
    safe_id = if identifier, do: String.replace(identifier, ~r/[^a-zA-Z0-9_\-]/, ""), else: nil
    workspace_path = if safe_id, do: Path.join(Config.workspace_root(), safe_id), else: nil

    case Evaluator.evaluate_and_record(run_id, run_context, workspace_path) do
      {:ok, eval} -> eval
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("Evaluation failed: #{Exception.message(error)}")
      nil
  end

  # Checked in order; the first category whose needles appear in the inspected
  # reason wins, and an unmatched reason is a crash.
  @error_message_categories [
    {"max_retries_exhausted", ["max_retries_exhausted"]},
    {"timeout", ["timeout", "Timeout"]},
    {"stall", ["stall", "Stall"]},
    {"rate_limit", ["rate_limit", "429"]},
    {"spawn_failure", ["spawn"]}
  ]

  defp categorize_error(:normal), do: %{message: nil, category: nil}

  defp categorize_error({:shutdown, :stopped}),
    do: %{message: "stopped via dashboard", category: "stopped"}

  defp categorize_error({:terminated, :dashboard_stopped}),
    do: %{message: "stopped via dashboard", category: "stopped"}

  defp categorize_error({:terminated, :needs_help}),
    do: %{message: "escalated for human review", category: "needs_human"}

  defp categorize_error({:terminated, :terminal_state}),
    do: %{message: "issue moved to terminal Linear state", category: "terminal_state"}

  defp categorize_error({:terminated, :not_routable}),
    do: %{message: "issue no longer routed to this worker", category: "not_routable"}

  defp categorize_error({:terminated, :label_removed}),
    do: %{message: "the issue's routing label was removed", category: "label_removed"}

  defp categorize_error({:terminated, :non_active_state}),
    do: %{message: "issue moved to non-active Linear state", category: "non_active_state"}

  defp categorize_error({:terminated, :stalled}),
    do: %{message: "agent stalled with no activity", category: "stall"}

  defp categorize_error({:terminated, reason}),
    do: %{message: "terminated: #{inspect(reason)}", category: "terminated"}

  defp categorize_error(reason) do
    message = inspect(reason)

    category =
      Enum.find_value(@error_message_categories, "crash", fn {candidate, needles} ->
        if Enum.any?(needles, &(message =~ &1)), do: candidate
      end)

    %{message: message, category: category}
  end

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &flat_token_usage/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  # Recognizes a flat usage map like %{input_tokens: N, output_tokens: N, total_tokens: N}
  # produced by Claude Code's StreamParser.extract_usage/1.
  defp flat_token_usage(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp flat_token_usage(_), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  # ---------------------------------------------------------------------------
  # Phase-aware stall detection
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Pre-dispatch PR check
  # ---------------------------------------------------------------------------

  # Scan completed issues for open PRs with merge conflicts and re-dispatch them
  defp check_completed_pr_health(%State{completed: completed} = state) do
    if MapSet.size(completed) == 0 or available_slots(state) == 0 do
      state
    else
      # Collect completed entries that have PRs
      entries_with_prs =
        state.completed_history
        |> Enum.filter(fn entry ->
          entry[:outcome] == "completed" and is_binary(entry[:pr_url])
        end)
        |> Enum.uniq_by(& &1[:issue_identifier])

      Enum.reduce(entries_with_prs, state, &maybe_check_completed_entry_pr(&2, &1))
    end
  end

  defp maybe_check_completed_entry_pr(%State{} = state, entry) do
    if available_slots(state) == 0 do
      state
    else
      check_completed_entry_pr(state, entry)
    end
  end

  defp check_completed_entry_pr(%State{} = state, entry) do
    pr_url = entry[:pr_url]
    identifier = entry[:issue_identifier]

    if pr_conflicting?(pr_url) do
      Logger.info("PR has merge conflicts for completed issue #{identifier}: #{pr_url}")

      # Find the Linear UUID for this identifier in the completed set
      # by checking the history database
      case History.runs_for_issue(identifier) do
        [%{issue_id: issue_id} | _] when is_binary(issue_id) ->
          %{state | completed: MapSet.delete(state.completed, issue_id)}

        _ ->
          state
      end
    else
      state
    end
  rescue
    error ->
      Logger.debug("PR health check failed for #{entry[:issue_identifier]}: #{Exception.message(error)}")
      state
  end

  defp pr_conflicting?(pr_url) when is_binary(pr_url) do
    # Extract owner/repo and PR number from URL
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, pr_url) do
      [_, repo, number] ->
        case System.cmd("gh", ["pr", "view", number, "--repo", repo, "--json", "mergeable", "--jq", ".mergeable"], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output) == "CONFLICTING"
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp pr_conflicting?(_), do: false

  # The PR the evaluator recorded for this issue's last run, if it is still
  # open — ground truth from the workspace's actual pushed branch. Falls back
  # (nil) when the issue has never run, the PR closed/merged, or gh fails.
  defp stored_pr(%Issue{identifier: identifier}) when is_binary(identifier) do
    case History.latest_pr_url(identifier) do
      url when is_binary(url) ->
        case open_pr_info(url) do
          %{url: url, branch: branch} -> {:pr_exists, url, branch}
          nil -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp stored_pr(_issue), do: nil

  # PRs the Linear-GitHub integration attached to the issue — repo-agnostic
  # ground truth, so the PR is found even when label-based repo routing points
  # at the wrong repo (GEA-5247: a gf_platform PR under a `3.0` label was
  # invisible to the branch search). Oldest open PR wins: the original work PR
  # beats later side-PRs sharing the issue prefix.
  defp attachment_pr(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Client.fetch_issue_pr_urls(issue_id) do
      {:ok, [_ | _] = urls} ->
        urls
        |> Enum.map(&open_pr_info/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.number)
        |> case do
          [%{url: url, branch: branch} | _] -> {:pr_exists, url, branch}
          [] -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp attachment_pr(_issue), do: nil

  defp open_pr_info(url) when is_binary(url) do
    with {out, 0} <-
           System.cmd("gh", ["pr", "view", url, "--json", "state,headRefName,number"], stderr_to_stdout: true),
         {:ok, %{"state" => "OPEN", "headRefName" => branch, "number" => number}} <-
           Jason.decode(out) do
      %{url: url, branch: branch, number: number}
    else
      _ -> nil
    end
  end

  defp check_existing_pr(%Issue{identifier: identifier, labels: labels} = issue) when is_binary(identifier) do
    repos = repos_for_labels(labels)
    lower = String.downcase(identifier)

    # Try exact branch names first, then prefix match for verbose Linear branch names
    # (e.g. "gea-1205-some-description" starts with "gea-1205")
    branches = [identifier, lower]

    # Exact branch match first. Fall back: list all open PRs and find one whose
    # branch starts with the identifier. Also check the issue's gitBranchName
    # from Linear if available.
    result =
      find_pr_by_exact_branch(repos, branches) ||
        find_pr_by_branch_prefix(repos, lower) ||
        find_pr_by_linear_branch(repos, Map.get(issue, :git_branch_name))

    case result do
      nil -> :no_pr
      %{url: url, branch: branch} -> {:pr_exists, url, branch}
      url when is_binary(url) -> {:pr_exists, url, nil}
    end
  rescue
    _ -> :no_pr
  end

  defp check_existing_pr(_issue), do: :no_pr

  defp find_pr_by_exact_branch(repos, branches) do
    Enum.find_value(repos, fn repo ->
      # Exact branch match
      Enum.find_value(branches, &open_pr_for_head(repo, &1))
    end)
  end

  defp find_pr_by_branch_prefix(repos, lower) do
    Enum.find_value(repos, &open_pr_with_branch_prefix(&1, lower))
  end

  defp find_pr_by_linear_branch(repos, branch) when is_binary(branch) and branch != "" do
    Enum.find_value(repos, &open_pr_for_head(&1, branch))
  end

  defp find_pr_by_linear_branch(_repos, _branch), do: nil

  defp open_pr_for_head(repo, branch) do
    case System.cmd("gh", ["pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--json", "url,headRefName", "--jq", ".[0]"], stderr_to_stdout: true) do
      {output, 0} -> parse_pr_result(output)
      _ -> nil
    end
  end

  defp open_pr_with_branch_prefix(repo, lower) do
    case System.cmd("gh", ["pr", "list", "--repo", repo, "--state", "open", "--json", "url,headRefName", "--limit", "50"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} when is_list(prs) -> Enum.find_value(prs, &pr_with_branch_prefix(&1, lower))
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp pr_with_branch_prefix(pr, lower) do
    branch = pr["headRefName"] || ""

    if String.starts_with?(String.downcase(branch), lower <> "-") or String.downcase(branch) == lower do
      parse_pr_result(Jason.encode!(pr))
    end
  end

  defp parse_pr_result(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, %{"url" => url, "headRefName" => branch}} when is_binary(url) and url != "" ->
        %{url: url, branch: branch}

      _ ->
        if trimmed != "" and String.starts_with?(trimmed, "http") do
          trimmed
        else
          nil
        end
    end
  end

  defp repos_for_labels(labels) when is_list(labels) do
    has_platform = Enum.any?(labels, fn l -> String.downcase(l) |> String.starts_with?("2.0") end)
    has_procurement = Enum.any?(labels, fn l -> String.downcase(l) |> String.starts_with?("3.0") end)

    cond do
      has_platform and has_procurement -> ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]
      has_platform -> ["GearFlowDev/gf_platform"]
      has_procurement -> ["GearFlowDev/gf_procurement"]
      true -> ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]
    end
  end

  defp repos_for_labels(_), do: ["GearFlowDev/gf_platform", "GearFlowDev/gf_procurement"]

  defp phase_stall_elapsed_ms(running_entry, now) do
    case Map.get(running_entry, :phase_changed_at) do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Screenshot URL tracking
  # ---------------------------------------------------------------------------

  defp screenshot_urls_for_update(running_entry, %{raw: raw}) when is_map(raw) do
    existing = Map.get(running_entry, :screenshot_urls, [])
    new_urls = StreamParser.extract_screenshot_urls(raw)

    case new_urls do
      [] -> existing
      urls -> Enum.uniq(existing ++ urls)
    end
  end

  defp screenshot_urls_for_update(running_entry, _update),
    do: Map.get(running_entry, :screenshot_urls, [])

  # ---------------------------------------------------------------------------
  # Phase transition event recording
  # ---------------------------------------------------------------------------

  defp record_phase_transition_events(old_entry, new_entry, issue_id) do
    run_id = Map.get(new_entry, :history_run_id)
    unless run_id, do: throw(:skip)

    old_phase = Map.get(old_entry, :phase)
    new_phase = Map.get(new_entry, :phase)
    old_pr_url = Map.get(old_entry, :pr_url)
    new_pr_url = Map.get(new_entry, :pr_url)
    old_screenshots = Map.get(old_entry, :screenshot_urls, [])
    new_screenshots = Map.get(new_entry, :screenshot_urls, [])

    now = DateTime.utc_now()

    # Phase change event
    if new_phase != old_phase and new_phase != nil do
      History.record_event(%{
        run_id: run_id,
        event_type: "phase_change",
        payload: %{from: old_phase, to: new_phase},
        timestamp: now
      })

      # Milestone events (deduplicated via phase check)
      record_milestone_event(run_id, old_phase, new_phase, now)
    end

    # PR created milestone
    if new_pr_url != nil and old_pr_url == nil do
      History.record_event(%{
        run_id: run_id,
        event_type: "milestone_pr_created",
        payload: %{pr_url: new_pr_url},
        timestamp: now
      })
    end

    # Screenshot captured
    if length(new_screenshots) > length(old_screenshots) do
      new_urls = new_screenshots -- old_screenshots

      Enum.each(new_urls, fn url ->
        History.record_event(%{
          run_id: run_id,
          event_type: "screenshot_captured",
          payload: %{url: url, issue_id: issue_id},
          timestamp: now
        })
      end)
    end

    :ok
  catch
    :skip -> :ok
  end

  defp record_milestone_event(run_id, old_phase, new_phase, now) do
    normalized_new = new_phase && String.downcase(new_phase)
    normalized_old = old_phase && String.downcase(old_phase)

    cond do
      entered_phase?(normalized_new, normalized_old, "implement") ->
        History.record_event(%{
          run_id: run_id,
          event_type: "milestone_first_edit",
          payload: %{phase: new_phase},
          timestamp: now
        })

      entered_phase?(normalized_new, normalized_old, "test") ->
        History.record_event(%{
          run_id: run_id,
          event_type: "milestone_tests_run",
          payload: %{phase: new_phase},
          timestamp: now
        })

      true ->
        :ok
    end
  end

  defp entered_phase?(normalized_new, normalized_old, keyword) do
    (normalized_new && String.contains?(normalized_new, keyword)) and
      (normalized_old == nil or not String.contains?(normalized_old, keyword))
  end

  defp record_max_retries_event(_state, issue_id, identifier, attempt) do
    Logger.info("Recording max_retries_exhausted for issue_id=#{issue_id} issue_identifier=#{identifier} attempt=#{attempt}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer actions: stop, retry, cancel
  # ---------------------------------------------------------------------------

  @spec stop_issue(String.t()) :: :ok | {:error, :not_running}
  def stop_issue(issue_id), do: stop_issue(__MODULE__, issue_id)

  @spec stop_issue(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def stop_issue(server, issue_id) do
    GenServer.call(server, {:stop_issue, issue_id})
  end

  @spec retry_issue_manual(String.t()) :: :ok | {:error, :not_found}
  def retry_issue_manual(issue_id), do: retry_issue_manual(__MODULE__, issue_id)

  @spec retry_issue_manual(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def retry_issue_manual(server, issue_id) do
    GenServer.call(server, {:retry_issue_manual, issue_id})
  end

  @spec force_dispatch_identifier(String.t()) :: :ok | {:error, term()}
  def force_dispatch_identifier(identifier),
    do: force_dispatch_identifier(__MODULE__, identifier)

  @spec force_dispatch_identifier(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def force_dispatch_identifier(server, identifier) do
    GenServer.call(server, {:force_dispatch_identifier, identifier})
  end

  @spec cancel_retry(String.t()) :: :ok | {:error, :not_found}
  def cancel_retry(issue_id), do: cancel_retry(__MODULE__, issue_id)

  @spec cancel_retry(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def cancel_retry(server, issue_id) do
    GenServer.call(server, {:cancel_retry, issue_id})
  end
end
