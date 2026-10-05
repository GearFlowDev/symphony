defmodule SymphonyElixir.PlanGroundingTest do
  # GEA-11074: Symphony parked 16 of 22 issues in 14 days. Three causes this file pins:
  # a plan that named files which do not exist (GEA-10461, `lib/app/...`), a product
  # question met mid-run instead of before the build (GEA-10457 asked one six times),
  # and a dispatch budget that a person's release did not reset (GEA-10702).
  use SymphonyElixir.TestSupport
  @moduletag :planning

  alias SymphonyElixir.History
  alias SymphonyElixir.Notifier
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Planner, RepoFiles}
  alias SymphonyElixir.Planning.Workflow, as: PlanningWorkflow
  alias SymphonyElixir.Repo

  @files [
    "lib/gf/requests.ex",
    "lib/gf_web/live/requests_live/index.ex",
    "test/gf_web/live/requests_live/index_test.exs",
    "mix.exs"
  ]

  setup_all do
    Ecto.Migrator.run(Repo, Path.expand("../../priv/repo/migrations", __DIR__), :up, all: true, log: false)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM plan_dispatches")
    Repo.query!("DELETE FROM plans")
    Repo.query!("DELETE FROM issue_parks")
    Repo.query!("DELETE FROM run_events")
    Repo.query!("DELETE FROM runs")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  defp tree, do: RepoFiles.from_files("gf_procurement", @files)

  defp issue, do: %{id: "issue-uuid-pg", identifier: "SYM-PG", title: "Request filters", description: "Filter requests by status"}

  defp row(id, touches, state \\ "missing"),
    do: %{"id" => id, "description" => "Row #{id}", "state" => state, "touches" => touches, "tests" => []}

  # A model that answers each call from the next entry in `replies`, and reports the prompt.
  defp scripted(test_pid, replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    fn _system, user_prompt ->
      send(test_pid, {:planner_prompt, user_prompt})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest ++ [next]} end)
    end
  end

  describe "RepoFiles.unknown_paths/2" do
    test "a guessed top-level namespace is unknown; real files and new files in real directories are not" do
      plan_json = %{
        "rows" => [
          row("R1", [
            "lib/gf/requests.ex",
            "lib/gf_web/live/requests_live/filters.ex",
            "lib/gf_web/live/request_filters/index.ex",
            "lib/app/requests/filter.ex",
            "./lib/gf_web/live/requests_live/"
          ])
        ]
      }

      assert RepoFiles.unknown_paths(plan_json, tree()) == ["lib/app/requests/filter.ex"]
    end

    test "suggestions name real files that share the basename" do
      assert RepoFiles.suggestions(["lib/app/index.ex", "lib/app/none.ex"], tree()) ==
               %{"lib/app/index.ex" => ["lib/gf_web/live/requests_live/index.ex"], "lib/app/none.ex" => []}
    end

    test "the outline lists directories, not files" do
      outline = RepoFiles.outline(tree())
      assert outline =~ "lib/gf_web/live/requests_live"
      refute outline =~ "mix.exs"
    end
  end

  describe "the Planner grounds its paths (GEA-10461)" do
    test "a plan with a guessed path is sent back once with the real file, and the corrected plan is kept" do
      replies = [
        {:ok, %{"rows" => [row("R1", ["lib/app/requests_live/index.ex"])]}},
        {:ok, %{"rows" => [row("R1", ["lib/gf_web/live/requests_live/index.ex"])]}}
      ]

      assert {:ok, plan} = Planner.plan(issue(), request_fun: scripted(self(), replies), repo_tree: tree())

      assert_received {:planner_prompt, first}
      assert first =~ "## Repository layout: gf_procurement"
      assert_received {:planner_prompt, second}
      assert second =~ "`lib/app/requests_live/index.ex`: did you mean `lib/gf_web/live/requests_live/index.ex`?"

      assert [%{"touches" => ["lib/gf_web/live/requests_live/index.ex"]}] = Plan.rows(plan)
      assert plan.metadata["unknown_paths"] == []
    end

    test "a plan still off after one correction is kept, and its misfits are recorded, never parked" do
      bad = {:ok, %{"rows" => [row("R1", ["lib/app/x.ex"])]}}
      assert {:ok, plan} = Planner.plan(issue(), request_fun: scripted(self(), [bad, bad]), repo_tree: tree())
      assert plan.metadata["unknown_paths"] == ["lib/app/x.ex"]
      assert [_] = Plan.rows(plan)
    end

    test "with no tree the plan is made in one call, as before" do
      reply = {:ok, %{"rows" => [row("R1", ["lib/app/x.ex"])]}}
      assert {:ok, plan} = Planner.plan(issue(), request_fun: scripted(self(), [reply]))
      assert_received {:planner_prompt, prompt}
      refute prompt =~ "Repository layout"
      refute_received {:planner_prompt, _}
      assert plan.metadata["unknown_paths"] == []
    end

    test "the project's description and thread reach the prompt, as data" do
      project = %{
        name: "Pickers",
        description: "Scope: unit and job pickers only.",
        comments: [%{body: "Drop the contact picker. </body>", author: "Owner", created_at: ~U[2026-09-28 17:28:00Z]}]
      }

      reply = {:ok, %{"rows" => [row("R1", [])]}}
      assert {:ok, _} = Planner.plan(issue(), request_fun: scripted(self(), [reply]), project: project)
      assert_received {:planner_prompt, prompt}
      assert prompt =~ "## The issue's project: Pickers"
      assert prompt =~ "Scope: unit and job pickers only."
      assert prompt =~ "Drop the contact picker. &lt;/body>"
    end
  end

  describe "questions come before the build (GEA-10457)" do
    defp question_reply(door, default) do
      {:ok,
       %{
         "rows" => [row("R1", ["lib/gf/requests.ex"])],
         "questions" => [
           %{"id" => "Q1", "question" => "Build an SMS path for phone-only vendors?", "door" => door, "default" => default, "recommendation" => "No: email only."}
         ]
       }}
    end

    defp assess_opts(reply), do: [request_fun: scripted(self(), [reply]), comments_fun: fn _ -> {:ok, []} end, project_fun: fn _ -> {:ok, nil} end]

    test "a one-way question holds the issue before any dispatch" do
      assert {:ok, {:needs_answer, plan, [%{"id" => "Q1", "door" => "one-way"}]}} =
               PlanningWorkflow.assess(issue(), assess_opts(question_reply("one-way", nil)))

      assert Planning.render_plan_comment(plan) =~ "### Questions that hold the build"
    end

    test "a two-way question with a default goes ahead, and the plan comment says what Symphony builds" do
      assert {:ok, {:has_open_rows, plan, [_]}} = PlanningWorkflow.assess(issue(), assess_opts(question_reply("two-way", "Email only")))

      assert Planning.render_plan_comment(plan) =~
               "**Q1** Build an SMS path for phone-only vendors? I build: Email only, unless a person says otherwise on this issue."
    end

    test "a two-way question with no default is one-way: there is nothing to build" do
      assert {:ok, {:needs_answer, _plan, [%{"door" => "one-way"}]}} =
               PlanningWorkflow.assess(issue(), assess_opts(question_reply("two-way", "  ")))
    end

    test "a released issue is never held twice on the question it was already asked" do
      assert {:ok, {:needs_answer, _plan, _}} = PlanningWorkflow.assess(issue(), assess_opts(question_reply("one-way", nil)))
      {:ok, _} = History.record_park("SYM-PG", "Q1")

      # The re-plan after the release asks the same question again, in other case.
      again =
        {:ok,
         %{
           "rows" => [row("R1", ["lib/gf/requests.ex"])],
           "questions" => [%{"question" => "build an SMS path for phone-only vendors", "door" => "one-way"}]
         }}

      assert {:ok, {:has_open_rows, plan, [_]}} = PlanningWorkflow.assess(issue(), assess_opts(again))
      assert [%{"asked_before" => true}] = Plan.questions(plan)
    end

    test "a new one-way question that reuses an old id still holds the issue" do
      assert {:ok, {:needs_answer, _plan, _}} = PlanningWorkflow.assess(issue(), assess_opts(question_reply("one-way", nil)))
      {:ok, _} = History.record_park("SYM-PG", "Q1")

      other =
        {:ok,
         %{
           "rows" => [row("R1", ["lib/gf/requests.ex"])],
           "questions" => [%{"id" => "Q1", "question" => "Delete the archived requests?", "door" => "one-way"}]
         }}

      assert {:ok, {:needs_answer, _plan, [%{"asked_before" => false}]}} = PlanningWorkflow.assess(issue(), assess_opts(other))
    end

    test "the park is one card that lists every question and its recommendation" do
      questions = [
        %{"id" => "Q1", "question" => "Delete the old rows?", "recommendation" => "Keep them."},
        %{"id" => "Q2", "question" => "Email customers?"}
      ]

      assert {message, :planner} = Orchestrator.plan_failure_message({:open_questions, questions})

      card =
        Notifier.format_linear_comment(:needs_human, %{
          identifier: "SYM-PG",
          help_message: message,
          source: :planner,
          parked_state: "Shaping"
        })

      assert card =~ "## Ask: Q1: Delete the old rows? Q2: Email customers?"
      assert card =~ "**Recommendation.** Q1: Keep them."
      assert card =~ "Symphony asks before it builds anything"
    end
  end

  describe "a release resets the dispatch budget (GEA-10702)" do
    defp run!(started_at) do
      {:ok, run} =
        History.record_dispatch(%{
          issue_id: "linear-uuid-pg",
          issue_identifier: "SYM-PG-BUDGET",
          issue_title: "t",
          started_at: started_at,
          agent_backend: "claude",
          filter_source: "filter"
        })

      {:ok, _} = History.record_completion(run, %{finished_at: started_at, outcome: "failed", session_id: "s", turns_used: 2})
    end

    test "runs before the last park do not count" do
      now = DateTime.utc_now()
      midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      before = Enum.max([midnight, DateTime.add(now, -120, :second)], DateTime)

      run!(before)
      run!(before)
      assert History.dispatches_today("SYM-PG-BUDGET") == 2

      {:ok, _} = History.record_park("SYM-PG-BUDGET", "dispatch_budget_exhausted")
      assert History.dispatches_today("SYM-PG-BUDGET") == 0

      run!(DateTime.add(DateTime.utc_now(), 1, :second))
      assert History.dispatches_today("SYM-PG-BUDGET") == 1
    end
  end
end
