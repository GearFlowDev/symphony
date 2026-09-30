defmodule SymphonyElixir.Planning.Grader do
  @moduledoc """
  Grades a worker dispatch's diff against the rows it was assigned.

  The Grader is the load-bearing piece of the "premature-victory workaround":
  workers will declare done while their diff is still incomplete, so the
  orchestrator runs the Grader after EVERY dispatch and only trusts the
  Grader's verdict.

  Returns a structured grade JSON:

      %{
        "verdict" => "approve" | "request_changes" | "blocked",
        "rationale" => "one-paragraph summary",
        "rows" => [
          %{"id" => "R1", "state" => "done", "note" => "test/x.exs:42 covers it"},
          %{"id" => "R3", "state" => "partial", "note" => "missing the empty-state branch"}
        ]
      }

  The verdict is `approve` only if every assigned row is `done`. Any
  `partial` or `missing` row makes the verdict `request_changes`. `blocked`
  is reserved for "the dispatch couldn't even run" (test failure on
  unrelated code, broken slot, etc.).
  """

  require Logger

  alias SymphonyElixir.Claude.OneShot
  alias SymphonyElixir.Config
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.Dispatch

  @grade_system_prompt """
  You are the grading component of an autonomous engineering orchestrator.

  Given a plan, the rows a worker was assigned, and a structured summary of
  the branch state (file list, line counts, commit subjects) plus optional
  test output, evaluate which rows are closed. Workers routinely overstate
  their progress, so be skeptical — but also know that `touches:` paths in
  the plan rows are GUESSES from the Planner that may not match the
  codebase's actual layout. Match by intent and filename pattern, not
  literal-string equality.

  Hard requirements:

  1. Reply with ONLY a JSON object. No prose. No code fences.
  2. The JSON shape is:

       {
         "verdict": "approve" | "request_changes" | "blocked",
         "rationale": "1-3 sentences explaining the verdict",
         "rows": [
           {
             "id": "R1",
             "state": "done" | "partial" | "missing",
             "note": "specific evidence: file path or commit SHA from the summary, or what's still missing"
           }
         ]
       }

  3. Include an entry for every assigned row, even if untouched.
  4. Verdict rules:
       - "approve": every assigned row state is "done"
       - "request_changes": at least one row is "partial" or "missing"
       - "blocked": the dispatch couldn't run at all (slot broken, tests
         crash on unrelated code, missing infrastructure). Use sparingly.
  5. `note` fields must cite specific evidence from the summary — the file
     name with stat line, or a commit SHA + subject. "Looks good" is not a
     note; "lib/gf_web/live/maintenance_view_live.ex (+1234 lines), commit
     ee303e2f 'C03 inline editors'" is.
  6. **Path matching is fuzzy.** A row that says
     `touches: ["assets/js/hooks/local_storage_state.ts"]` may correspond
     to an actual file at `assets/js/hooks/local_storage_draft.js` — same
     concept, different name. If the diff has a file whose path
     reasonably maps to the row's intent (matching basename pattern, same
     module/namespace, same described feature in the row description),
     count it as covering the row. Don't mark a row "missing" just because
     the literal path string isn't in the diff.
     **Whole-namespace mismatch (common).** The Planner often emits
     stock-Phoenix paths (`lib/app/…`, `lib/app_web/…`, `test/app/…`) for a
     repo that actually uses a different namespace (`lib/gf/…`,
     `lib/gf_web/…`, etc.). When the plan's namespace does not appear in the
     diff at ALL, do not try to line paths up — drop `touches` entirely and
     grade the row purely on (a) its description vs. the diff's actual files
     and content, (b) the commit subjects, and (c) the test output. A
     namespace-wrong `touches` path is never, by itself, grounds for
     "missing": the question is whether the described work landed, not
     whether it landed at the guessed path.
  7. **Commit subjects are first-class evidence.** A commit subject like
     `GEA-2772: C03-maintenance-view — inline editors` directly closes
     row `C03-maintenance-view`. Use commit subjects to confirm row
     closures even when files don't precisely match the row's `touches:`
     hints.
  8. **PR description is a separate evidence channel.** A row whose
     deliverable is a PR-body update (e.g. "Update PR description with
     per-contract status table", "Add Contract Audit section to PR
     description", "List deferrals on PR") will NOT appear in `git diff`
     — workers edit PR bodies via `gh pr edit --body`. If a "## PR
     description" section is present in the evidence below, scan it for
     the row's required content (status table, audit section, etc.) and
     mark `done` if present. **Do not mark such rows missing just
     because they don't appear in the diff** — that's the wrong evidence
     channel. If the PR description IS present and clearly contains
     what the row asked for, the row is `done`.
  9. If a row's diff exists but its test is missing, that row is `partial`,
     not `done`. The contract is "implementation + test", not "implementation
     alone". Exception: rows whose `tests` list is empty (frontend-only,
     documentation, research deliverables) — for those the committed artifact
     itself is the contract; grade on whether the diff delivers what the row
     describes (sections present, content substantive, references real).
  10. Cross-cutting / parity rows need INTEGRATION evidence, not just the
      component file. A row that makes an overlay or shared component "flippable"
      or "at parity" is `partial` if the diff only touches the component's own
      file and skips the surfaces the row names — the layout shell, the sibling
      pages' call sites, or the router. Grade `done` only when the diff shows the
      integration itself (e.g. the bell added to each section page, the
      dismiss/route helper, the over-any-section safety-net route), because that
      shell/integration surface is exactly where parity migrations silently fall
      short while every content row looks complete.
  11. **Use the change census (if a "## Change census" section is present).**
      It lists, for functions this branch changed, the call sites in `lib/`
      that the diff did NOT touch. The most common real defect is a changed
      function whose contract moved (new/renamed/removed argument, changed
      return shape or behavior) while one of these un-touched callers kept the
      old usage. For each row that changed such a function: check the census's
      listed callers, and if the row's change would break or silently misfire
      at a caller the diff left alone, mark the row `partial` (note the specific
      file:line from the census). Also: a census "Possibly dead code" entry for
      a module a row was supposed to wire in means that row is `partial`, not
      `done`; a census "Delivery" warning about unpushed commits means the
      work isn't really on the branch — grade against what's actually pushed.
      The census is heuristic and greps by call syntax, so it over-reports
      common names — a bare mention is not proof of a defect; only downgrade a
      row when the changed contract genuinely leaves a listed caller stale.
  12. **Proof rows are graded from the proof channels, never from the diff
      alone.** Some rows ask for proof rather than code: a green test run, a
      CodeRabbit review and resolved threads, screenshots or a report on the
      issue. Sending such a row back to an Implement worker changes nothing,
      so grade it from the channel that holds its proof:
       - A green run: "## PR state on the head". The row's test is on the
         branch and every CI check on the head passed → the run is green.
         An empty "## Test output" is not, by itself, grounds for `partial`.
       - A review: CodeRabbit's latest review is on the head and no review
         thread is unresolved → the review row is `done`.
       - Proof posted to the issue: "## Issue comments during this dispatch".
       - **Screenshots, a browser walk or any visual proof of UI on the
         branch fall to the Test phase.** Once every row is done, the tester
         walks the app, posts screenshots in its report, and its verdict
         gates the hand-off. Grade such a row on its code alone, and when that
         is done, mark it `done` with the note "screenshots fall to the Test
         phase". Never keep a row `partial` only for screenshots.
       - A proof channel that is absent from the evidence is unknown, not
         failed: grade the row's code, and say in the note which proof you
         could not see.
  """

  @doc """
  Grade a dispatch and persist the result.

  Inputs:
    * `dispatch` — the `Dispatch.t()` row to grade. `assigned_rows_json`
      and `plan_id` must already be set.
    * `evidence`:
        * `:diff` — text of the worker's diff against the base branch
        * `:test_output` — text of the test run output
        * `:plan` — the parent `Plan.t()` (passed in to avoid a refetch)
        * `:notes` — optional extra context (e.g. "browser walkthrough
          screenshots attached on Linear")
        * `:pr_state` / `:issue_comments` — the rendered sections from
          `ProofEvidence`: CI and review state on the PR head, and the issue
          comments posted during the dispatch (GEA-10667)

  Returns the updated `Dispatch.t()` with `grade_json` populated.
  """
  @spec grade(Dispatch.t(), keyword()) :: {:ok, Dispatch.t()} | {:error, term()}
  def grade(%Dispatch{} = dispatch, evidence) do
    plan = Keyword.fetch!(evidence, :plan)

    user_prompt = build_user_prompt(dispatch, plan, evidence)
    opts = Keyword.put(evidence, :model, Config.claude_grade_model())

    with {:ok, grade_json} <- OneShot.request_json(@grade_system_prompt, user_prompt, opts),
         :ok <- validate_shape(grade_json, dispatch),
         {:ok, updated} <- Planning.record_grade(dispatch, grade_json) do
      {:ok, updated}
    else
      {:error, _} = err ->
        Logger.error("Grader failed for dispatch=#{dispatch.id}: #{inspect(err)}")
        err
    end
  end

  @doc false
  @spec system_prompt() :: String.t()
  def system_prompt, do: @grade_system_prompt

  @doc false
  @spec build_user_prompt(Dispatch.t(), SymphonyElixir.Planning.Plan.t(), keyword()) :: String.t()
  def build_user_prompt(dispatch, plan, evidence) do
    diff = Keyword.get(evidence, :diff, "")
    test_output = Keyword.get(evidence, :test_output, "")
    notes = Keyword.get(evidence, :notes, "")
    pr_body = Keyword.get(evidence, :pr_body)
    census = Keyword.get(evidence, :census, "")
    pr_state = Keyword.get(evidence, :pr_state)
    issue_comments = Keyword.get(evidence, :issue_comments)

    assigned = Map.get(dispatch.assigned_rows_json || %{}, "rows", [])
    plan_rows = Map.get(plan.plan_json || %{}, "rows", [])

    sections = [
      "## Plan (full context)\n\n```json\n#{Jason.encode!(plan_rows, pretty: true)}\n```",
      "## Rows assigned to this dispatch\n\n```json\n#{Jason.encode!(assigned, pretty: true)}\n```",
      "## Branch state vs base\n\nThis is a structured summary (file list + commit subjects + diff stats), NOT a full diff dump. `assigned_rows[*].touches` are Planner GUESSES — treat them as hints only. Grade each row on its description against the actual files and content plus the commit subjects; if a row's `touches` paths don't appear (e.g. the plan used a different namespace), match on intent + commits rather than marking it missing.\n\n```\n#{truncate(diff, 200_000)}\n```",
      census_section(census),
      pr_body_section(pr_body),
      pr_state,
      issue_comments,
      "## Test output\n\n```\n#{truncate(test_output, 20_000)}\n```",
      if(notes != "", do: "## Additional context\n\n#{notes}", else: nil)
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n---\n\n")
  end

  defp census_section(census) when is_binary(census) do
    trimmed = String.trim(census)

    if trimmed == "" or String.starts_with?(trimmed, "(change census: no") do
      nil
    else
      "## Change census (callers the diff may have forgotten)\n\nHeuristic, code-derived evidence: for functions this branch changed, these are call sites in `lib/` that the diff did NOT touch, plus new modules with no caller and any unpushed commits. Use it to apply requirement 11 — if a changed function's contract moved and a listed caller wasn't updated to match, the owning row is `partial`, not `done`.\n\n```\n#{truncate(trimmed, 40_000)}\n```"
    end
  end

  defp census_section(_), do: nil

  defp pr_body_section(nil), do: nil
  defp pr_body_section(""), do: nil

  defp pr_body_section(pr_body) do
    "## PR description (live from GitHub)\n\nUse this to evaluate rows whose deliverable is a PR-description edit (status tables, contract audits, deferral lists). Workers update PR descriptions via `gh pr edit --body`, which leaves no `git diff` trace — this section is the only evidence available for those rows.\n\n```\n#{truncate(pr_body, 50_000)}\n```"
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "\n\n[...truncated]"
  end

  defp truncate(text, _) when is_binary(text), do: text
  defp truncate(_, _), do: ""

  defp validate_shape(%{"verdict" => v, "rows" => rows}, dispatch)
       when v in ["approve", "request_changes", "blocked"] and is_list(rows) do
    # Check row shape FIRST: a non-map row would raise on `&1["id"]` below,
    # turning a malformed grade into a crash instead of an error tuple.
    if Enum.all?(rows, &valid_row?/1) do
      assigned_ids =
        (dispatch.assigned_rows_json || %{})
        |> Map.get("rows", [])
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      graded_ids = rows |> Enum.map(& &1["id"]) |> MapSet.new()

      if MapSet.subset?(assigned_ids, graded_ids) do
        :ok
      else
        missing = MapSet.difference(assigned_ids, graded_ids) |> MapSet.to_list()
        {:error, {:invalid_grade_shape, "missing grades for rows: #{inspect(missing)}"}}
      end
    else
      {:error, {:invalid_grade_shape, "rows missing required fields"}}
    end
  end

  defp validate_shape(_, _), do: {:error, {:invalid_grade_shape, "bad top-level keys"}}

  defp valid_row?(%{"id" => id, "state" => state})
       when is_binary(id) and state in ["done", "partial", "missing"],
       do: true

  defp valid_row?(_), do: false
end
