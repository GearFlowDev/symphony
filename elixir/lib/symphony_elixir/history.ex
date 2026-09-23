defmodule SymphonyElixir.History do
  @moduledoc """
  Query interface for run history and aggregate metrics.
  """

  import Ecto.Query
  alias SymphonyElixir.History.{Run, RunEvent, TesterVerdict}
  alias SymphonyElixir.Repo

  # ---------------------------------------------------------------------------
  # Write operations
  # ---------------------------------------------------------------------------

  @spec record_dispatch(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_dispatch(attrs) do
    attrs
    |> Run.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Record a tester verdict (from the `SYMPHONY_VERDICT` marker). This is the
  machine-readable source of truth the gate reads; the Linear report is for
  humans. Best-effort: a bad verdict string is dropped rather than raising.
  """
  @spec record_tester_verdict(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, TesterVerdict.t()} | {:error, Ecto.Changeset.t()}
  def record_tester_verdict(issue_identifier, verdict, commit_sha \\ nil, reason \\ nil) do
    # The SYMPHONY_VERDICT marker is re-extracted every time the session JSONL
    # is re-read, so an unguarded insert piles up duplicates (observed: 139
    # identical BLOCKED rows on one issue). Same verdict+sha as the latest row
    # is a no-op re-observation, not a new verdict.
    case latest_tester_verdict(issue_identifier) do
      %TesterVerdict{verdict: ^verdict, commit_sha: ^commit_sha} = existing ->
        {:ok, existing}

      _ ->
        %{issue_identifier: issue_identifier, verdict: verdict, commit_sha: commit_sha, reason: reason}
        |> TesterVerdict.create_changeset()
        |> Repo.insert()
    end
  end

  @doc """
  Count of runs dispatched for an issue since UTC midnight, excluding rows that
  never became a worker. The daily dispatch budget reads this.

  Two exclusions. `no_capacity` claim failures and `orphaned` sweep closures
  never reached an agent by construction. And neither did a run with no agent
  session and no turns: that is a dispatch that died in `before_run` — a failed
  provisioning hook, or an attempt the stall watchdog abandoned before a session
  existed. Counting those spent the budget on infrastructure faults rather than
  on issue churn, and blocked GEA-9699 at `12 dispatches since 00:00 UTC` with a
  message offering re-activation as the only way out (2026-09-22). The
  failure-retry cap, not this budget, is what bounds a hook that keeps failing.
  """
  @spec dispatches_today(String.t()) :: non_neg_integer()
  def dispatches_today(issue_identifier) when is_binary(issue_identifier) do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    Run
    |> where([r], r.issue_identifier == ^issue_identifier)
    |> where([r], r.started_at >= ^midnight)
    |> where([r], is_nil(r.outcome) or r.outcome not in ["no_capacity", "orphaned"])
    |> where([r], not (is_nil(r.session_id) and coalesce(r.turns_used, 0) == 0 and not is_nil(r.finished_at)))
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @doc """
  Count of finished WORKER runs for an issue — the no-progress breaker's cycle
  gate. Excludes `no_capacity`/`orphaned` rows: no agent ran, so nothing could
  have progressed, and counting them let a slot-starved retry loop append the
  same fingerprint three times and self-trip the breaker (GEA-4623,
  2026-07-15 20:14Z).
  """
  @spec finished_run_count(String.t()) :: non_neg_integer()
  def finished_run_count(issue_identifier) when is_binary(issue_identifier) do
    Run
    |> where([r], r.issue_identifier == ^issue_identifier)
    |> where([r], not is_nil(r.finished_at))
    |> where([r], is_nil(r.outcome) or r.outcome not in ["no_capacity", "orphaned"])
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @doc "The most recent tester verdict for an issue, or nil."
  @spec latest_tester_verdict(String.t()) :: TesterVerdict.t() | nil
  def latest_tester_verdict(issue_identifier) when is_binary(issue_identifier) do
    TesterVerdict
    |> where([v], v.issue_identifier == ^issue_identifier)
    |> order_by([v], desc: v.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec record_completion(Run.t() | String.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_completion(%Run{} = run, attrs) do
    run
    |> Run.completion_changeset(attrs)
    |> Repo.update()
  end

  def record_completion(run_id, attrs) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> record_completion(run, attrs)
    end
  end

  @doc """
  Close every run row still open (`finished_at IS NULL`). Called once at
  orchestrator startup: no run survives a restart (the startup reapers kill
  their tmux sessions and slot leases), so any open row is a leftover from a
  crash or kill and would make "active runs" queries lie forever.
  """
  @spec close_orphaned_runs() :: non_neg_integer()
  def close_orphaned_runs do
    now = DateTime.utc_now()

    {count, _} =
      Run
      |> where([r], is_nil(r.finished_at))
      |> Repo.update_all(set: [finished_at: now, outcome: "orphaned", error_category: "orphaned", updated_at: now])

    count
  end

  @doc """
  Persist a running run's in-progress totals (tokens, turns, phase) so the DB
  reflects an in-flight run and the figures survive a restart. Same partial-update
  mechanism as `record_completion/2`, just without the terminal fields.
  """
  @spec update_progress(String.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def update_progress(run_id, attrs) when is_binary(run_id), do: record_completion(run_id, attrs)

  @spec record_evaluation(Run.t() | String.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_evaluation(%Run{} = run, attrs) do
    run
    |> Run.evaluation_changeset(attrs)
    |> Repo.update()
  end

  def record_evaluation(run_id, attrs) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> record_evaluation(run, attrs)
    end
  end

  @spec record_escalation(String.t(), String.t(), String.t() | nil) ::
          {:ok, Run.t()} | {:error, term()}
  def record_escalation(run_id, escalation_type, message \\ nil) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        attrs = %{
          escalation_type: escalation_type,
          escalated_at: DateTime.utc_now(),
          needs_human: escalation_type == "needs_human",
          needs_human_message: message
        }

        run
        |> Run.completion_changeset(attrs)
        |> Repo.update()
    end
  end

  @spec record_event(map()) :: {:ok, RunEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(attrs) do
    attrs
    |> RunEvent.changeset()
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Read operations
  # ---------------------------------------------------------------------------

  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @spec get_run!(String.t()) :: Run.t()
  def get_run!(id), do: Repo.get!(Run, id)

  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(opts \\ []) do
    Run
    |> apply_filters(opts)
    |> order_by([r], desc: r.started_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc "Delete failed runs for an issue so the judge re-evaluates from scratch."
  @spec delete_failed_runs(String.t()) :: :ok
  def delete_failed_runs(issue_identifier) do
    run_ids =
      Run
      |> where([r], r.issue_identifier == ^issue_identifier and r.outcome == "failed")
      |> select([r], r.id)
      |> Repo.all()

    if run_ids != [] do
      RunEvent |> where([e], e.run_id in ^run_ids) |> Repo.delete_all()
      Run |> where([r], r.id in ^run_ids) |> Repo.delete_all()
    end

    :ok
  end

  @spec delete_all_runs(String.t()) :: :ok
  def delete_all_runs(issue_identifier) do
    run_ids =
      Run
      |> where([r], r.issue_identifier == ^issue_identifier)
      |> select([r], r.id)
      |> Repo.all()

    if run_ids != [] do
      RunEvent |> where([e], e.run_id in ^run_ids) |> Repo.delete_all()
      Run |> where([r], r.id in ^run_ids) |> Repo.delete_all()
    end

    :ok
  end

  @spec runs_for_issue(String.t()) :: [Run.t()]
  def runs_for_issue(issue_identifier) do
    Run
    |> where([r], r.issue_identifier == ^issue_identifier)
    |> order_by([r], desc: r.started_at)
    |> Repo.all()
  end

  @spec events_for_run(String.t()) :: [RunEvent.t()]
  def events_for_run(run_id) do
    RunEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], asc: e.timestamp)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Issue-level summary (for PhaseJudge)
  # ---------------------------------------------------------------------------

  @spec issue_summary(String.t()) :: map()
  def issue_summary(issue_identifier) do
    runs = runs_for_issue(issue_identifier)
    run_ids = Enum.map(runs, & &1.id)

    events =
      if run_ids != [] do
        RunEvent
        |> where([e], e.run_id in ^run_ids)
        |> order_by([e], asc: e.timestamp)
        |> Repo.all()
      else
        []
      end

    last_completed_at =
      runs
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.max_by(&DateTime.to_unix(&1.finished_at), fn -> nil end)
      |> then(fn r -> r && r.finished_at end)

    %{
      total_runs: length(runs),
      runs: runs,
      events: events,
      has_pr: Enum.any?(runs, &(&1.eval_pr_url != nil)),
      pr_url: runs |> Enum.find_value(& &1.eval_pr_url),
      has_evidence: Enum.any?(runs, &(&1.eval_evidence_posted == true)),
      has_tests: Enum.any?(runs, &(&1.eval_tests_written == true)),
      phases_seen: events |> extract_phases_from_events(),
      screenshots: events |> Enum.filter(&(&1.event_type == "screenshot_captured")),
      latest_outcome: runs |> List.first() |> then(fn r -> r && r.outcome end),
      last_completed_at: last_completed_at
    }
  end

  defp extract_phases_from_events(events) do
    events
    |> Enum.filter(&(&1.event_type == "phase_change"))
    |> Enum.map(fn e -> Map.get(e.payload || %{}, "to") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Aggregate metrics
  # ---------------------------------------------------------------------------

  @spec success_rate(keyword()) :: float()
  def success_rate(opts \\ []) do
    query = completed_runs_query(opts)

    total = Repo.aggregate(query, :count)
    successful = Repo.aggregate(where(query, [r], r.outcome == "completed"), :count)

    if total > 0, do: successful / total * 100.0, else: 0.0
  end

  @spec avg_score(keyword()) :: float()
  def avg_score(opts \\ []) do
    completed_runs_query(opts)
    |> where([r], not is_nil(r.eval_score))
    |> Repo.aggregate(:avg, :eval_score)
    |> then(fn
      nil -> 0.0
      avg -> avg / 1.0
    end)
  end

  @spec total_tokens(keyword()) :: integer()
  def total_tokens(opts \\ []) do
    completed_runs_query(opts)
    |> Repo.aggregate(:sum, :total_tokens)
    |> then(fn
      nil -> 0
      n -> n
    end)
  end

  @doc """
  Cumulative input/output/total tokens across an issue's completed runs.

  Each dispatch is its own run row, so summing them gives the issue's true
  running total even after the in-memory per-attempt counter resets to zero on
  an agent restart. Used to seed a fresh dispatch so the dashboard keeps
  counting up instead of dropping back to 0.
  """
  @spec issue_token_totals(String.t()) :: %{
          input_tokens: integer(),
          output_tokens: integer(),
          total_tokens: integer()
        }
  def issue_token_totals(issue_identifier) when is_binary(issue_identifier) do
    completed_runs_query(issue_identifier: issue_identifier)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0)
    })
    |> Repo.one() || %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  @doc """
  Cumulative code-change evidence across an issue's finished runs.

  The no-progress breaker needs a progress signal that exists BEFORE a PR does.
  These totals are recorded by the evaluator on every run, so a dispatch that
  closed a row and pushed is distinguishable from one that changed nothing.
  """
  @spec issue_change_totals(String.t()) :: %{
          files_changed: non_neg_integer(),
          lines_changed: non_neg_integer()
        }
  def issue_change_totals(issue_identifier) when is_binary(issue_identifier) do
    completed_runs_query(issue_identifier: issue_identifier)
    |> select([r], %{
      files_changed: coalesce(sum(r.eval_files_changed), 0),
      lines_changed: coalesce(sum(r.eval_lines_changed), 0)
    })
    |> Repo.one() || %{files_changed: 0, lines_changed: 0}
  end

  @doc "Most recent PR URL the evaluator recorded for an issue, or nil."
  @spec latest_pr_url(String.t()) :: String.t() | nil
  def latest_pr_url(identifier) when is_binary(identifier) do
    Run
    |> where([r], r.issue_identifier == ^identifier and not is_nil(r.eval_pr_url))
    |> order_by([r], desc: r.started_at)
    |> limit(1)
    |> select([r], r.eval_pr_url)
    |> Repo.one()
  end

  @doc """
  Most-recent PR URL per issue identifier, from runs that recorded one. Used to
  show an issue's open PR on the dashboard even on a run (running or completed)
  that did not itself detect the URL.
  """
  @spec pr_urls_by_issue(keyword()) :: %{optional(String.t()) => String.t()}
  def pr_urls_by_issue(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Run
    |> where([r], not is_nil(r.eval_pr_url) and not is_nil(r.issue_identifier))
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> select([r], {r.issue_identifier, r.eval_pr_url})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {identifier, url}, acc -> Map.put_new(acc, identifier, url) end)
  end

  @spec failure_breakdown(keyword()) :: [%{category: String.t(), count: integer()}]
  def failure_breakdown(opts \\ []) do
    completed_runs_query(opts)
    |> where([r], r.outcome == "failed")
    |> group_by([r], r.error_category)
    |> select([r], %{category: r.error_category, count: count()})
    |> order_by([r], desc: count())
    |> Repo.all()
  end

  @spec success_rate_by_label(keyword()) :: [%{label: String.t(), rate: float(), count: integer()}]
  def success_rate_by_label(opts \\ []) do
    # SQLite doesn't support unnest, so we do this in Elixir
    runs =
      completed_runs_query(opts)
      |> select([r], %{outcome: r.outcome, labels: r.issue_labels})
      |> Repo.all()

    runs
    |> Enum.flat_map(fn run ->
      Enum.map(run.labels || [], fn label -> {label, run.outcome} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {label, outcomes} ->
      total = length(outcomes)
      successful = Enum.count(outcomes, &(&1 == "completed"))
      %{label: label, rate: successful / total * 100.0, count: total}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @spec recent_completed(integer()) :: [Run.t()]
  def recent_completed(limit \\ 20) do
    Run
    |> where([r], not is_nil(r.finished_at))
    |> order_by([r], desc: r.finished_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp completed_runs_query(opts) do
    Run
    |> where([r], not is_nil(r.finished_at))
    |> apply_filters(opts)
  end

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_outcome(Keyword.get(opts, :outcome))
    |> maybe_filter_after(Keyword.get(opts, :after))
    |> maybe_filter_before(Keyword.get(opts, :before))
    |> maybe_filter_issue(Keyword.get(opts, :issue_identifier))
    |> maybe_filter_min_score(Keyword.get(opts, :min_score))
  end

  defp maybe_filter_outcome(query, nil), do: query
  defp maybe_filter_outcome(query, outcome), do: where(query, [r], r.outcome == ^outcome)

  defp maybe_filter_after(query, nil), do: query

  defp maybe_filter_after(query, %Date{} = date) do
    {:ok, dt} = NaiveDateTime.new(date, ~T[00:00:00])
    where(query, [r], r.started_at >= ^dt)
  end

  defp maybe_filter_after(query, %DateTime{} = dt), do: where(query, [r], r.started_at >= ^dt)

  defp maybe_filter_before(query, nil), do: query

  defp maybe_filter_before(query, %Date{} = date) do
    {:ok, dt} = NaiveDateTime.new(date, ~T[23:59:59])
    where(query, [r], r.started_at <= ^dt)
  end

  defp maybe_filter_before(query, %DateTime{} = dt), do: where(query, [r], r.started_at <= ^dt)

  defp maybe_filter_issue(query, nil), do: query
  defp maybe_filter_issue(query, id), do: where(query, [r], r.issue_identifier == ^id)

  defp maybe_filter_min_score(query, nil), do: query
  defp maybe_filter_min_score(query, score), do: where(query, [r], r.eval_score >= ^score)
end
