defmodule SymphonyElixir.Planning.Planner do
  @moduledoc """
  Generates a structured plan for a Linear issue.

  The Planner runs once per issue, and again when a person releases the issue
  from a park (`Planning.Workflow.assess/2`, GEA-10664). Given:

    * the issue body
    * any in-repo process docs the issue references
    * the current branch diff against the base branch (if a WIP branch exists)
    * on a re-plan, the prior plan and the comments posted since the park

  it produces a plan with rows that workers can close one-by-one. Each row
  has a stable id, file-path hints, test hints, dependencies, and an initial
  state (`missing` for fresh issues, or `partial` / `done` if an audit
  determines the WIP branch already covers it).
  """

  require Logger

  alias SymphonyElixir.Claude.OneShot
  alias SymphonyElixir.Config
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.Plan

  @plan_system_prompt """
  You are the planning component of an autonomous engineering orchestrator.

  Given a Linear issue body, optional in-repo process docs, and an optional
  diff summary describing existing work-in-progress, output a structured
  plan that downstream worker agents will execute one row at a time.

  Hard requirements:

  1. Reply with ONLY a JSON object. No prose. No code fences.
  2. The JSON must have shape:

       {
         "rows": [
           {
             "id": "R1",
             "description": "One-sentence description of what this row delivers.",
             "touches": ["lib/path/to/file.ex", "test/path/to/file_test.exs"],
             "tests": ["test/path/to/file_test.exs"],
             "depends_on": [],
             "state": "missing",
             "rationale": null
           }
         ],
         "out_of_scope": [],
         "notes": "Optional: one-paragraph context for graders."
       }

  3. Row IDs are short stable identifiers (R1, R2, ... or domain-meaningful
     like "issues-list-filters"). Reuse existing IDs if a prior plan was
     supplied as context.
  4. `touches` lists every file the row will create or modify. Workers use
     this to partition rows that don't collide on files.
  5. `state` is one of:
       - "missing": not started
       - "partial": some work exists but it's incomplete
       - "done": already implemented (only if audit signal proves it)
       - "deferred": reviewer-approved out-of-scope (rare; usually goes in
         `out_of_scope` instead).
     `rationale` is a short string when state is `partial` / `done`,
     describing the evidence; null otherwise.
  6. Rows must be small enough that a single worker dispatch can close one
     in 1-3 commits. Split big features.
  7. Do NOT defer rows on your own. If a row feels too big, split it. Only
     items the issue body explicitly trims belong in `out_of_scope`.
  8. Test rows mean in-repo automated tests only — ExUnit/LiveView tests under
     `test/**/*_test.exs`. These repos have NO in-repo Playwright/Cypress/e2e
     harness (no `e2e/` dir, no `playwright.config`, no `@playwright` dep), so a
     row whose deliverable is an `e2e/*.spec.ts` or any browser-spec file would
     be dead and unrunnable — never emit one. End-to-end browser behavior is
     verified live in the Test phase by a separate sub-agent driving system
     Playwright (`npx playwright`); that is the Test phase's job, not an
     implementation row, so do not add a plan row for it. For a UI change, the
     row's testable deliverable is the LiveView/ExUnit test.
  9. Parity migrations: plan the SHELL and INTEGRATION surface, not just content.
     The gaps a content-only plan misses live OUTSIDE the component's own file —
     in the app shell, the sibling pages, the router, and the interaction model.
     When the reference (e.g. React) renders a portal/sheet/modal, or is imported
     by more than one page, grep the reference for its call sites and interaction
     hooks and emit EXPLICIT rows for:
       - Interaction contract — how it mounts and dismisses: backdrop/scrim (or
         deliberately none), outside-click, Escape, focus, the back/close control.
         Name the reference's own guards (e.g. a pointer-down-outside +
         `isInteractiveTarget` handler) so the worker matches behavior, not guesses.
       - Responsive contract — what the layout does at each breakpoint, pinning the
         exact breakpoint token from the reference (do not guess `sm` vs `md`).
       - Call-site inventory — one row per surface that invokes the component (e.g.
         a notification bell on each section page), so the affordance exists
         everywhere the reference puts it, not only on the component's own route.
       - Routing contract — every URL that opens or closes it, the dismiss
         destination per entry point, and a safety-net route so a sibling path
         never crashes (an over-any-section `/:section/inbox`, not a `/:id`
         fall-through that casts "inbox" as a record id).
     A cross-cutting component (touches the layout shell or ≥2 sibling pages) is
     rarely one dispatch: split it along these seams, and say so in `notes`.
  10. Call-site completeness for ANY changed symbol — not just UI. The single
      most common failure is a change that lands in one place but not the
      others that must move with it: a function whose signature / return shape
      changes while some callers keep the old usage; a schema field or table
      whose new writer is added but the legacy write paths still bypass it; a
      new module that nothing calls. Whenever a row changes the contract of a
      backend symbol (a function's arguments or return, a schema field, a
      context API), it OWNS every site that must change with it. Either list
      those call sites explicitly in that row's `touches`, or emit a sibling
      "update all callers/writers of X" row that names them. State the sweep in
      `notes` ("changing `Foo.bar/2`'s return — callers in A, B, C must be
      updated") so the worker and grader know completeness spans more than the
      defining file. The gaps live in the CALLERS of what you change, and a
      green test suite does not prove they were carried.

  Bias the plan toward what the issue body and process docs actually ask
  for. Do not invent rows the issue doesn't request.
  """

  @doc """
  Generate (or regenerate) a plan for the given issue and persist it.

  Inputs:
    * `issue` — a `SymphonyElixir.Linear.Issue` struct (or a map with the
      same shape)
    * `opts`:
        * `:process_docs` — list of `{path, content}` tuples for any
          in-repo process docs the issue references
        * `:audit_summary` — optional string summarizing the WIP branch's
          existing diff against the base, to seed `partial` / `done` states
        * `:prior_plan` — optional `Plan.t()` whose row IDs the new plan
          should preserve where rows still apply. A prior row that was `done`
          stays `done` when the new plan keeps its ID; a prior row the new
          plan leaves out is dropped.
        * `:comments_since_park` — the issue's comments posted after Symphony
          last parked it. A person's answer to the parked question is here,
          and it overrides the prior plan (GEA-10664).
        * `:request_fun` — `(system_prompt, user_prompt -> {:ok, map} | {:error, term})`;
          replaces the Claude call, for tests.

  Returns the persisted `Plan.t()` on success.
  """
  @spec plan(map(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(issue, opts \\ []) do
    user_prompt = build_user_prompt(issue, opts)

    with {:ok, plan_json} <- request_plan(user_prompt, opts),
         :ok <- validate_shape(plan_json),
         plan_json = keep_done_rows(plan_json, Keyword.get(opts, :prior_plan)),
         {:ok, plan} <-
           Planning.upsert_plan(%{
             issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
             issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
             status: "dispatching",
             plan_json: plan_json,
             metadata:
               (Keyword.get(opts, :metadata, %{}) || %{})
               |> Map.put("generated_at", DateTime.to_iso8601(DateTime.utc_now()))
           }) do
      # Post the plan to Linear so it's visible/reviewable (best-effort).
      {:ok, Planning.mirror_plan_to_linear(plan)}
    else
      {:error, _} = err ->
        Logger.error("Planner failed for issue=#{issue_id_for_log(issue)}: #{inspect(err)}")
        err
    end
  end

  # Plan on the configured plan model (e.g. fable). If that session errors —
  # most likely the model isn't available on this account/CLI — retry once on
  # the default model (opus).
  defp request_plan(user_prompt, opts) do
    case Keyword.get(opts, :request_fun) do
      request_fun when is_function(request_fun, 2) -> request_fun.(@plan_system_prompt, user_prompt)
      _ -> request_plan_from_claude(user_prompt, opts)
    end
  end

  defp request_plan_from_claude(user_prompt, opts) do
    plan_model = Config.claude_plan_model()

    case OneShot.request_json(@plan_system_prompt, user_prompt, Keyword.put(opts, :model, plan_model)) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        fallback = Config.claude_model()

        if plan_model && fallback && fallback != plan_model do
          Logger.warning("Planner model #{plan_model} failed (#{inspect(reason)}); retrying with #{fallback}")
          OneShot.request_json(@plan_system_prompt, user_prompt, Keyword.put(opts, :model, fallback))
        else
          err
        end
    end
  end

  defp build_user_prompt(issue, opts) do
    body = Map.get(issue, :description) || Map.get(issue, "description") || ""
    title = Map.get(issue, :title) || Map.get(issue, "title") || ""
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || ""
    labels = Map.get(issue, :labels) || Map.get(issue, "labels") || []

    process_docs = Keyword.get(opts, :process_docs, [])
    audit_summary = Keyword.get(opts, :audit_summary)
    prior_plan = Keyword.get(opts, :prior_plan)

    sections = [
      "## Linear issue\n\n- ID: #{identifier}\n- Title: #{title}\n- Labels: #{Enum.join(labels, ", ")}\n\n### Body\n\n#{body}",
      process_docs_section(process_docs),
      audit_section(audit_summary),
      prior_plan_section(prior_plan),
      comments_since_park_section(Keyword.get(opts, :comments_since_park, []))
    ]

    sections |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n---\n\n")
  end

  defp process_docs_section([]), do: nil

  defp process_docs_section(docs) when is_list(docs) do
    rendered =
      Enum.map_join(docs, "\n\n", fn {path, content} ->
        "### #{path}\n\n#{content}"
      end)

    "## Process docs\n\n#{rendered}"
  end

  defp audit_section(nil), do: nil
  defp audit_section(""), do: nil

  defp audit_section(summary) when is_binary(summary) do
    "## WIP branch audit summary\n\n#{summary}\n\nUse this to mark rows `partial` or `done` where the WIP branch already covers them."
  end

  defp prior_plan_section(nil), do: nil

  defp prior_plan_section(%Plan{plan_json: %{"rows" => rows}}) when is_list(rows) do
    encoded = Jason.encode!(rows, pretty: true)
    "## Prior plan rows (preserve IDs where possible)\n\n```json\n#{encoded}\n```"
  end

  defp prior_plan_section(_), do: nil

  defp comments_since_park_section([]), do: nil

  defp comments_since_park_section(comments) when is_list(comments) do
    rendered =
      Enum.map_join(comments, "\n\n", fn comment ->
        at = if match?(%DateTime{}, comment[:created_at]), do: DateTime.to_iso8601(comment.created_at), else: "?"
        "### #{comment[:author] || "Unknown"} at #{at}\n\n#{comment[:body] || ""}"
      end)

    """
    ## Comments since the issue was parked (these override the prior plan)

    Symphony parked this issue with a question, and a person released it. Their
    answer is in these comments and in the issue body above. Re-plan from the
    body and these comments: drop every prior row they rule out, add any row they
    ask for, and keep the ID of every prior row that still applies. Do not ask
    again a question these comments answer.

    #{rendered}
    """
  end

  defp comments_since_park_section(_), do: nil

  @doc """
  Carry the prior plan's `done` rows into a re-plan: a new row with the ID of a
  prior `done` row stays `done`. A prior row the new plan leaves out is dropped.
  """
  @spec keep_done_rows(map(), Plan.t() | nil) :: map()
  def keep_done_rows(%{"rows" => rows} = plan_json, %Plan{} = prior_plan) do
    done_by_id =
      prior_plan
      |> Plan.rows()
      |> Enum.filter(&(&1["state"] == "done"))
      |> Map.new(&{&1["id"], &1})

    kept =
      Enum.map(rows, fn row ->
        case Map.get(done_by_id, row["id"]) do
          nil -> row
          done -> Map.merge(row, %{"state" => "done", "rationale" => done["rationale"] || row["rationale"]})
        end
      end)

    Map.put(plan_json, "rows", kept)
  end

  def keep_done_rows(plan_json, _prior_plan), do: plan_json

  defp validate_shape(%{"rows" => rows}) when is_list(rows) do
    if Enum.all?(rows, &valid_row?/1) do
      :ok
    else
      {:error, {:invalid_plan_shape, "rows missing required fields"}}
    end
  end

  defp validate_shape(_), do: {:error, {:invalid_plan_shape, "missing rows array"}}

  defp valid_row?(%{"id" => id, "description" => desc, "state" => state})
       when is_binary(id) and is_binary(desc) and state in ["missing", "partial", "done", "deferred"],
       do: true

  defp valid_row?(_), do: false

  defp issue_id_for_log(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"
  end
end
