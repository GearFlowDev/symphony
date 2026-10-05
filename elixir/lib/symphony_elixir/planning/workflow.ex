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

  alias SymphonyElixir.Config
  alias SymphonyElixir.History
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Auditor, Dispatch, Grader, Plan, Planner, RepoFiles}

  @type assess_result ::
          {:has_open_rows, Plan.t(), [map()]}
          | {:complete, Plan.t()}
          | {:needs_answer, Plan.t(), [map()]}

  @doc """
  Read-only assessment of whether the plan has open rows.

    * If no plan exists for the issue, generate one (single LLM call) from
      the body and the issue's comments, and return its open-row state. A
      person's scope ruling can come before the first plan (GEA-10756).
    * If a person released the issue from a park after the plan was made,
      re-plan from the current body and the whole thread. The person's answer
      to a parked question lives there, and the old plan would ask the same
      question again (GEA-10664). A ruling older than the prior plan counts
      too: that plan may have ignored it (GEA-10756).
    * If a plan exists with `missing` or `partial` rows, return
      `{:has_open_rows, plan, rows}`.
    * If every row is `done` or `deferred`, return `{:complete, plan}`.
    * If the plan carries a one-way question no earlier plan asked, return
      `{:needs_answer, plan, questions}` before any of that: the issue waits
      for a person before the build, not in the middle of it (GEA-11074).

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
          fresh_plan(issue, identifier, opts)

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

  # Fresh plan — read the thread, then run the Auditor so the Planner sees
  # what's already on the WIP branch, and feed the summary in as
  # :audit_summary. Auditor failures don't block planning; we just plan from
  # the issue body alone. A failed comment read defers the plan: a plan made
  # without a person's ruling would never read that ruling again.
  defp fresh_plan(issue, identifier, opts) do
    fetch_comments = Keyword.get(opts, :comments_fun, &fetch_comments/1)
    read = if issue_id(issue), do: fetch_comments.(issue_id(issue)), else: {:ok, []}

    case read do
      {:ok, comments} ->
        audit_summary = Keyword.get(opts, :audit_fun, &audit_summary/3).(issue, identifier, opts)

        Planner.plan(
          issue,
          opts
          |> Keyword.put(:audit_summary, audit_summary)
          |> Keyword.put(:comments, comments)
          |> put_grounding(issue, identifier)
        )

      {:error, reason} ->
        Logger.warning("Plan of #{identifier} deferred: comments unreadable: #{inspect(reason)}")
        {:error, {:comments_unavailable, reason}}
    end
  end

  defp replan_after_release(issue, plan, parked_at, opts) do
    Logger.info("Re-planning #{plan.issue_identifier}: released after a park at #{DateTime.to_iso8601(parked_at)}")
    fetch_comments = Keyword.get(opts, :comments_fun, &fetch_comments/1)
    planned_at = plan_generated_at(plan)

    # A failed read defers the re-plan: a plan made without the person's
    # answer would stamp a newer generated_at and never be re-made.
    # A plan is stored with the issue's Linear id, so an issue map without one
    # still reads, and re-saves, the right thread.
    issue = if issue_id(issue), do: issue, else: Map.put(issue, :id, plan.issue_id)

    case fetch_comments.(issue_id(issue)) do
      {:ok, comments} ->
        planner_opts =
          opts
          |> Keyword.put(:prior_plan, plan)
          |> Keyword.put(:comments, comments)
          |> Keyword.put(:prior_planned_at, planned_at)
          |> Keyword.put(:metadata, Map.put(plan.metadata || %{}, "replanned_after_park", DateTime.to_iso8601(parked_at)))
          |> put_grounding(issue, plan.issue_identifier)

        Planner.plan(issue, planner_opts)

      {:error, reason} ->
        Logger.warning("Re-plan of #{plan.issue_identifier} deferred: comments unreadable: #{inspect(reason)}")
        {:error, {:comments_unavailable, reason}}
    end
  end

  # What grounds a plan in the world (GEA-11074): the project's rulings, so a
  # question the project answered is never asked, and the repository's real
  # tree, so `touches` names files that exist. Neither read blocks a plan: a
  # plan made without them is the plan Symphony made before.
  defp put_grounding(opts, issue, identifier) do
    project =
      case Keyword.get(opts, :project_fun, &fetch_project/1).(issue_id(issue)) do
        {:ok, project} ->
          project

        {:error, reason} ->
          Logger.warning("Plan of #{identifier}: project unreadable, planning without it: #{inspect(reason)}")
          nil
      end

    repo_tree =
      case Keyword.get(opts, :repo_tree_fun, &RepoFiles.load/2).(issue, opts) do
        {:ok, tree} -> tree
        _ -> nil
      end

    opts |> Keyword.put(:project, project) |> Keyword.put(:repo_tree, repo_tree)
  end

  # Only a Linear tracker has projects; the memory tracker the tests run on must
  # never reach the real API through an ambient LINEAR_API_KEY.
  defp fetch_project(issue_id) when is_binary(issue_id) do
    if Config.tracker_kind() == "linear", do: Client.fetch_issue_project(issue_id), else: {:ok, nil}
  end

  defp fetch_project(_issue_id), do: {:ok, nil}

  defp issue_id(issue) do
    case Map.get(issue, :id) || Map.get(issue, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # With no Linear id there is no thread to read, and an empty list would pass
  # for a thread with no answer.
  defp fetch_comments(issue_id) when is_binary(issue_id) and issue_id != "", do: Client.read_all_issue_comments(issue_id)
  defp fetch_comments(_issue_id), do: {:error, :no_issue_id}

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
    case {Plan.open_questions(plan), Plan.open_rows(plan)} do
      {[_ | _] = questions, _rows} -> {:needs_answer, plan, questions}
      {[], []} -> {:complete, plan}
      {[], rows} -> {:has_open_rows, plan, rows}
    end
  end

  @doc """
  Record the start of a worker dispatch.

  Call this only after `assess/2` returned `{:has_open_rows, plan, rows}`
  AND the orchestrator has committed to dispatching a worker. Creates a
  `Dispatch` row with the assigned rows, ready for the Grader to find
  later. `phase:` records the retask phase (for example `"Fix CI"`) on the row.
  """
  @spec start_implement_dispatch(Plan.t(), [map()], keyword()) ::
          {:ok, Dispatch.t()} | {:error, term()}
  def start_implement_dispatch(%Plan{} = plan, rows, opts \\ []) do
    Planning.record_dispatch(%{
      plan_id: plan.id,
      role: "implement",
      slot_name: Keyword.get(opts, :slot_name),
      assigned_rows_json: assigned_rows_json(rows, Keyword.get(opts, :phase)),
      started_at: DateTime.utc_now()
    })
  end

  # The phase rides beside the rows, so a reader can tell a Fix CI row-closer from an
  # Implement one. The tester gate needs that (GEA-10755). Rows alone keep the old shape.
  defp assigned_rows_json(rows, phase) when is_binary(phase), do: %{"rows" => rows, "phase" => phase}
  defp assigned_rows_json(rows, _phase), do: %{"rows" => rows}

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
