defmodule SymphonyElixir.Planning.Workflow do
  @moduledoc """
  Plan-driven dispatch state machine — the sole dispatch authority (there is no
  phase judge). Owns the lifecycle:

      planning → dispatching → grading → (done | redispatching → dispatching)

  The orchestrator generates a plan from the issue, dispatches a row-closer for
  the open rows, grades the result, and repeats. Once the code rows are done it
  dispatches the Test tester sub-agent; a clean tester report finishes the issue,
  a REQUEST_CHANGES reopens rows for another Implement pass.

  Phase A scope (no fanout): a single worker dispatch closes all open rows
  on each pass. Phase B will partition rows across N workers.
  """

  require Logger

  alias SymphonyElixir.History
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Auditor, Dispatch, Grader, Plan, Planner}

  @type assess_result ::
          {:has_open_rows, Plan.t(), [map()]}
          | {:complete, Plan.t()}

  @doc """
  Read-only assessment of whether the plan has open rows.

    * If no plan exists for the issue, generate one (single LLM call) and
      return its open-row state.
    * If a person released the issue from a park after the plan was made,
      re-plan from the current body and the comments since the park. The
      person's answer to a parked question lives there, and the old plan
      would ask the same question again (GEA-10664).
    * If a plan exists with `missing` or `partial` rows, return
      `{:has_open_rows, plan, rows}`.
    * If every row is `done` or `deferred`, return `{:complete, plan}`.

  This does NOT create a `Dispatch` row — call `start_implement_dispatch/3`
  separately when the orchestrator commits to dispatching a worker against
  these rows.
  """
  @spec assess(map(), keyword()) :: {:ok, assess_result()} | {:error, term()}
  def assess(issue, opts \\ []) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    plan_result =
      case Planning.get_plan_by_issue(identifier) do
        nil ->
          # Fresh plan — run the Auditor first so the Planner sees what's
          # already on the WIP branch, and feed the summary in as
          # :audit_summary. Auditor failures don't block planning; we just
          # plan from the issue body alone.
          audit_summary = audit_summary(issue, identifier, opts)
          Planner.plan(issue, Keyword.put(opts, :audit_summary, audit_summary))

        %Plan{} = plan ->
          case park_after_plan(plan, identifier, opts) do
            nil -> {:ok, plan}
            parked_at -> replan_after_release(issue, plan, parked_at, opts)
          end
      end

    case plan_result do
      {:ok, plan} -> {:ok, open_rows_result(plan)}
      err -> err
    end
  end

  # The last park's time when it is newer than the plan, else nil. A re-plan
  # stamps a newer generated_at, so one release re-plans exactly once.
  defp park_after_plan(plan, identifier, opts) do
    last_parked_at = Keyword.get(opts, :last_parked_at_fun, &History.last_parked_at/1)

    case last_parked_at.(identifier) do
      %DateTime{} = parked_at ->
        if DateTime.compare(parked_at, plan_generated_at(plan)) == :gt, do: parked_at

      _ ->
        nil
    end
  end

  defp plan_generated_at(%Plan{metadata: %{"generated_at" => at}} = plan) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> dt
      _ -> plan.inserted_at
    end
  end

  defp plan_generated_at(%Plan{inserted_at: inserted_at}), do: inserted_at

  defp replan_after_release(issue, plan, parked_at, opts) do
    Logger.info("Re-planning #{plan.issue_identifier}: released after a park at #{DateTime.to_iso8601(parked_at)}")
    fetch_comments = Keyword.get(opts, :comments_fun, &fetch_comments/1)

    comments =
      issue
      |> issue_id()
      |> fetch_comments.()
      |> Enum.filter(&posted_after?(&1, parked_at))

    planner_opts =
      opts
      |> Keyword.put(:prior_plan, plan)
      |> Keyword.put(:comments_since_park, comments)
      |> Keyword.put(:metadata, Map.put(plan.metadata || %{}, "replanned_after_park", DateTime.to_iso8601(parked_at)))

    Planner.plan(issue, planner_opts)
  end

  defp issue_id(issue), do: Map.get(issue, :id) || Map.get(issue, "id")

  defp fetch_comments(issue_id) when is_binary(issue_id) do
    case Client.fetch_all_issue_comments(issue_id) do
      {:ok, comments} -> comments
      _ -> []
    end
  end

  defp fetch_comments(_issue_id), do: []

  defp posted_after?(%{created_at: %DateTime{} = at}, parked_at), do: DateTime.compare(at, parked_at) == :gt
  defp posted_after?(_comment, _parked_at), do: false

  defp audit_summary(issue, identifier, opts) do
    case Auditor.audit(issue, pr_url: opts[:pr_url]) do
      {:ok, summary} ->
        summary

      {:error, reason} ->
        Logger.warning("Auditor failed for #{identifier}: #{inspect(reason)}; planning from issue body only")
        nil
    end
  end

  defp open_rows_result(plan) do
    case Plan.open_rows(plan) do
      [] -> {:complete, plan}
      rows -> {:has_open_rows, plan, rows}
    end
  end

  @doc """
  Record the start of a worker dispatch.

  Call this only after `assess/2` returned `{:has_open_rows, plan, rows}`
  AND the orchestrator has committed to dispatching a worker. Creates a
  `Dispatch` row with the assigned rows, ready for the Grader to find
  later.
  """
  @spec start_implement_dispatch(Plan.t(), [map()], keyword()) ::
          {:ok, Dispatch.t()} | {:error, term()}
  def start_implement_dispatch(%Plan{} = plan, rows, opts \\ []) do
    Planning.record_dispatch(%{
      plan_id: plan.id,
      role: "implement",
      slot_name: Keyword.get(opts, :slot_name),
      assigned_rows_json: %{"rows" => rows},
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Grade a finished worker dispatch and update the plan with row-level results.

  Returns `{:ok, {:approve | :request_changes | :blocked, plan}}`.
  The verdict tells the orchestrator whether to advance phases or
  re-dispatch Implement with the still-open rows.
  """
  @spec grade_dispatch(Dispatch.t(), keyword()) ::
          {:ok, {atom(), Plan.t()}} | {:error, term()}
  def grade_dispatch(%Dispatch{} = dispatch, evidence) do
    plan = Keyword.fetch!(evidence, :plan)

    case Grader.grade(dispatch, evidence) do
      {:ok, %Dispatch{grade_json: grade_json}} ->
        case merge_grade_into_plan(plan, grade_json) do
          {:ok, updated_plan} -> {:ok, {verdict_atom(grade_json["verdict"]), updated_plan}}
          {:error, reason} -> {:error, {:merge_grade_failed, reason}}
        end

      err ->
        err
    end
  end

  # Map the grader's verdict string to an atom WITHOUT String.to_atom/1: the
  # grade JSON is model output, and String.to_atom on untrusted strings can
  # exhaust the atom table and crash the VM. Anything unexpected is :blocked.
  defp verdict_atom("approve"), do: :approve
  defp verdict_atom("request_changes"), do: :request_changes
  defp verdict_atom(_), do: :blocked

  # Merge grader row states into the plan's row list. Each graded row updates
  # the matching plan row's `state` and `rationale`. Rows not in the grader
  # output are left untouched (e.g. rows from a different worker's slice).
  defp merge_grade_into_plan(%Plan{} = plan, grade_json) do
    by_id =
      grade_json
      |> Map.get("rows", [])
      |> Map.new(fn row -> {row["id"], row} end)

    updated_rows =
      Plan.rows(plan)
      |> Enum.map(fn row ->
        case Map.get(by_id, row["id"]) do
          nil ->
            row

          graded ->
            row
            |> Map.put("state", normalize_state(graded["state"]))
            |> Map.put("rationale", graded["note"] || row["rationale"])
        end
      end)

    case Planning.replace_rows(plan, updated_rows) do
      {:ok, updated} -> {:ok, Planning.mirror_plan_to_linear(updated)}
      other -> other
    end
  end

  defp normalize_state("done"), do: "done"
  defp normalize_state("partial"), do: "partial"
  defp normalize_state("missing"), do: "missing"
  defp normalize_state(_), do: "missing"

  @doc "Returns true if every row in the plan is `done` or `deferred`."
  @spec plan_complete?(Plan.t()) :: boolean()
  def plan_complete?(%Plan{} = plan) do
    Plan.rows(plan)
    |> Enum.all?(fn row -> row["state"] in ["done", "deferred"] end)
  end

  @doc """
  Mark a plan as `done` once the orchestrator has confirmed all rows are
  closed. The Test phase happens AFTER this — Workflow only owns Implement.
  """
  @spec mark_plan_done(Plan.t()) :: {:ok, Plan.t()} | {:error, term()}
  def mark_plan_done(%Plan{} = plan), do: Planning.set_plan_status(plan, "done")
end
