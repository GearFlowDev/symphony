defmodule SymphonyElixir.Claude.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Claude Code.

  Drop-in replacement for `SymphonyElixir.AgentRunner` (which uses Codex).
  Same public interface: `run/3` with identical argument shapes and message
  protocol so the orchestrator can dispatch to either backend.

  Each issue runs in one long-lived interactive Claude Code session hosted in a
  tmux session (`Claude.TmuxCLI`). Prompts are delivered per turn and the
  structured event stream is read from the session's JSONL file by
  `Claude.SessionWatcher`, which also marks turn boundaries. This avoids
  `claude -p`, which bills against Anthropic's programmatic credit pool.
  """

  import Bitwise

  require Logger
  alias SymphonyElixir.Claude.{SessionWatcher, StreamParser, TmuxCLI}
  alias SymphonyElixir.{Config, Linear.Client, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting Claude agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting),
               :ok <- run_claude_turns(workspace, issue, claude_update_recipient, opts) do
            :ok
          else
            {:error, :hook_no_capacity} ->
              # No free pool slot right now — exit cleanly so the orchestrator
              # backs off and retries, instead of raising (which records a crash).
              Logger.info("No pool slot available for #{issue_context(issue)}; backing off")
              exit({:shutdown, :no_capacity})

            {:error, reason} ->
              Logger.error("Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Claude agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp claude_event_handler(recipient, issue) do
    fn event ->
      send_claude_update(recipient, issue, event)
    end
  end

  # Emit updates in the same {:codex_worker_update, ...} format the orchestrator
  # expects, so we stay compatible without rewriting the orchestrator.
  #
  # Token usage IS attached per event: interactive Claude reports per-message usage
  # whose normalized total grows with the (single, long-running) session context,
  # and the orchestrator's monotonic delta accounting tracks that growing total —
  # so the dashboard token count climbs live as the agent works, rather than only
  # updating at turn boundaries (a run is usually one long turn under max_turns=0).
  defp send_claude_update(recipient, %Issue{id: issue_id}, event)
       when is_binary(issue_id) and is_pid(recipient) do
    session_id = StreamParser.extract_session_id(event)
    usage = StreamParser.extract_usage(event)
    event_type = Map.get(event, :event_type, :unknown)

    send(
      recipient,
      {:codex_worker_update, issue_id,
       %{
         event: event_type,
         timestamp: DateTime.utc_now(),
         session_id: session_id,
         usage: usage,
         raw: event
       }}
    )

    :ok
  end

  defp send_claude_update(_recipient, _issue, _event), do: :ok

  # One update per completed turn, carrying only the turn number so the dashboard
  # TURN counter advances (interactive JSONL has no `init` event to count turns
  # from). Token usage rides on the per-event updates above, not here.
  defp send_turn_completed(recipient, %Issue{id: issue_id}, turn)
       when is_binary(issue_id) and is_pid(recipient) and is_integer(turn) do
    send(
      recipient,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         turn: turn,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: %{}
       }}
    )

    :ok
  end

  defp send_turn_completed(_recipient, _issue, _turn), do: :ok

  defp send_phase_update(recipient, %Issue{id: issue_id}, phase)
       when is_pid(recipient) and is_atom(phase) do
    send(
      recipient,
      {:codex_worker_update, issue_id,
       %{
         event: phase,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: %{}
       }}
    )

    :ok
  end

  defp send_phase_update(_recipient, _issue, _phase), do: :ok

  defp run_claude_turns(workspace, issue, claude_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    comment_fetcher =
      Keyword.get(opts, :comment_fetcher, &Client.fetch_issue_comments/2)

    ctx = %{
      workspace: workspace,
      recipient: claude_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      comment_fetcher: comment_fetcher,
      max_turns: max_turns,
      turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, Config.claude_turn_timeout_ms()),
      # Collaborators are injectable so the turn loop can be tested without a live
      # tmux session. Production uses the real modules.
      session_mod: Keyword.get(opts, :session_module, TmuxCLI),
      watcher_mod: Keyword.get(opts, :watcher_module, SessionWatcher)
    }

    session_id = uuid4()

    case ctx.session_mod.start_session(workspace, session_id, opts) do
      {:ok, session} ->
        try do
          run_session(ctx, issue, session, session_id)
        after
          ctx.session_mod.stop_session(session)
        end

      {:error, reason} ->
        {:error, {:start_session_failed, reason}}
    end
  end

  # Send the first prompt (which makes Claude create the JSONL), then start the
  # watcher on that file and drive the turn loop. The watcher reads from offset 0,
  # so turn 1's events are not lost even though it starts after the first prompt.
  defp run_session(ctx, issue, session, session_id) do
    prompt = build_turn_prompt(issue, ctx.opts, 1, ctx.max_turns, [])
    # Watermark for the next turn's comment fetch.
    turn_started_at = DateTime.utc_now()

    with :ok <- ctx.session_mod.send_prompt(session, prompt, 1),
         {:ok, jsonl_path} <- ctx.session_mod.await_jsonl(session_id),
         {:ok, watcher} <-
           ctx.watcher_mod.start_link(
             jsonl_path: jsonl_path,
             on_event: claude_event_handler(ctx.recipient, issue)
           ) do
      try do
        await_and_continue(ctx, issue, session, watcher, 1, turn_started_at, 0)
      after
        ctx.watcher_mod.stop(watcher)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Block until the turn already in flight completes, then run the between-turn
  # checks and either stop or send the next prompt and recurse.
  defp await_and_continue(ctx, issue, session, watcher, turn_number, comments_after, no_progress_count) do
    case ctx.watcher_mod.wait_for_turn(watcher, ctx.turn_timeout_ms) do
      {:ok, _turn_summary} ->
        send_turn_completed(ctx.recipient, issue, turn_number)

        # Check workspace progress after each turn.
        # Skip no-progress counting on early turns — investigation and planning
        # produce no git changes but are essential work (reading code, posting to Linear).
        progress = check_turn_progress(ctx.workspace)
        made_progress = progress.files_changed > 0 or progress.new_commits > 0 or turn_number <= 3
        next_no_progress = if made_progress, do: 0, else: no_progress_count + 1

        Logger.info(
          "Completed Claude agent turn for #{issue_context(issue)} workspace=#{ctx.workspace} turn=#{turn_number}/#{ctx.max_turns} progress=#{inspect(progress)} no_progress_count=#{next_no_progress}"
        )

        # Stop a stuck agent: no workspace progress for several turns in a row.
        # Completion routing (plan done / re-dispatch) is the orchestrator's job
        # via the Grader, not this in-run loop.
        if next_no_progress >= 3 do
          Logger.warning("No progress for #{next_no_progress} consecutive turns for #{issue_context(issue)}, stopping early")

          :ok
        else
          maybe_send_next_turn(ctx, issue, session, watcher, turn_number, comments_after, next_no_progress)
        end

      {:error, reason} ->
        Logger.error("Claude agent turn failed for #{issue_context(issue)} turn=#{turn_number}: #{inspect(reason)}")
        {:error, {:turn_failed, reason}}
    end
  end

  defp maybe_send_next_turn(ctx, issue, session, watcher, turn_number, comments_after, no_progress_count) do
    case continue_with_issue?(issue, ctx.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < ctx.max_turns ->
        next_turn = turn_number + 1
        Logger.info("Continuing Claude agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{ctx.max_turns}")

        comments = fetch_new_comments(refreshed_issue, ctx.comment_fetcher, next_turn, comments_after)
        prompt = build_turn_prompt(refreshed_issue, ctx.opts, next_turn, ctx.max_turns, comments)
        # Advance the watermark so the next turn only sees newer comments.
        turn_started_at = DateTime.utc_now()

        case ctx.session_mod.send_prompt(session, prompt, next_turn) do
          :ok ->
            await_and_continue(ctx, refreshed_issue, session, watcher, next_turn, turn_started_at, no_progress_count)

          {:error, reason} ->
            {:error, {:send_prompt_failed, reason}}
        end

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active")

        :ok

      {:done, _refreshed_issue} ->
        :ok
    end
  end

  # RFC 4122 version-4 UUID. Claude Code's --session-id requires a valid UUID;
  # this is also the JSONL filename we locate the session by.
  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = c |> band(0x0FFF) |> bor(0x4000)
    d = d |> band(0x3FFF) |> bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _comments) do
    case Keyword.get(opts, :retask_phases) do
      nil ->
        # Fresh dispatch — start with Investigate phase
        PromptBuilder.build_phase_prompt(issue, "Investigate", opts)

      [single_phase] ->
        # Single-phase dispatch (discrete-phase model)
        PromptBuilder.build_phase_prompt(issue, single_phase, opts)

      missing_phases ->
        # Legacy multi-phase fallback
        completed_phases = Keyword.get(opts, :completed_phases, [])
        PromptBuilder.build_retask_prompt(issue, missing_phases, completed_phases, opts)
    end
  end

  defp build_turn_prompt(issue, opts, turn_number, max_turns, comments) do
    # A single-phase dispatch (Test, Resolve Review, Fix CI, ...) must not get
    # the generic Implement-flavored continuation — telling a read-only tester
    # to "close the assigned rows" derails it into a needs-help escalation.
    case Keyword.get(opts, :retask_phases) do
      [single_phase] ->
        PromptBuilder.build_phase_continuation_prompt(
          issue,
          single_phase,
          turn_number,
          max_turns,
          comments,
          assigned_rows: Keyword.get(opts, :assigned_rows)
        )

      _ ->
        PromptBuilder.build_continuation_prompt(issue, turn_number, max_turns, comments)
    end
  end

  defp fetch_new_comments(_issue, _comment_fetcher, 1, _comments_after), do: []

  defp fetch_new_comments(%Issue{id: issue_id}, comment_fetcher, _turn, comments_after)
       when is_binary(issue_id) do
    case comment_fetcher.(issue_id, comments_after) do
      {:ok, comments} -> comments
      _ -> []
    end
  end

  defp fetch_new_comments(_issue, _comment_fetcher, _turn, _comments_after), do: []

  # Retry schedule for the between-turns issue-state refresh. One transient
  # transport error (a closed keep-alive connection, a network blip) must not
  # kill a whole multi-turn run — re-dispatching throws away the crashed turn's
  # uncommitted work. Retry briefly; if Linear still can't answer, fail OPEN
  # (assume the issue is still active and keep working). The refresh only exists
  # to stop work when an issue is moved to a terminal state; the next turn and
  # the orchestrator's own poll loop re-check, so working one extra turn on a
  # since-closed issue is far cheaper than discarding a turn on an open one.
  @issue_refresh_retry_delays_ms [2_000, 5_000, 10_000]

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case fetch_issue_state_with_retry(issue_id, issue_state_fetcher, @issue_refresh_retry_delays_ms) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        Logger.warning("Issue state refresh failed after retries for #{issue_context(issue)}: #{inspect(reason)}; assuming still active and continuing")

        {:continue, issue}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp fetch_issue_state_with_retry(issue_id, issue_state_fetcher, delays) do
    case issue_state_fetcher.([issue_id]) do
      {:error, reason} when delays != [] ->
        [delay | rest] = delays

        Logger.warning("Issue state refresh failed for issue_id=#{issue_id}: #{inspect(reason)}; retrying in #{delay}ms")

        Process.sleep(delay)
        fetch_issue_state_with_retry(issue_id, issue_state_fetcher, rest)

      result ->
        result
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp check_turn_progress(workspace) do
    files_changed = count_git_changes(workspace)
    new_commits = count_new_commits(workspace)
    %{files_changed: files_changed, new_commits: new_commits}
  end

  defp count_git_changes(workspace) do
    case System.cmd("git", ["diff", "--stat", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> length()

      _ ->
        0
    end
  end

  defp count_new_commits(workspace) do
    case System.cmd("git", ["log", "--oneline", "@{upstream}..HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> length()

      _ ->
        0
    end
  end
end
