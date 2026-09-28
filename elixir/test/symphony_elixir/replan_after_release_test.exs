defmodule SymphonyElixir.ReplanAfterReleaseTest do
  # GEA-10664: GEA-10459 parked asking whether to build vendor SMS (row R3). The owner
  # answered on the issue ("out of scope, re-plan without R3") and released it. The next
  # run read the stored plan, not the answer, and parked with the same question.
  use SymphonyElixir.TestSupport
  @moduletag :planning

  alias SymphonyElixir.History
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Planner}
  alias SymphonyElixir.Planning.Workflow, as: PlanningWorkflow
  alias SymphonyElixir.Repo

  @answer "Phone-only vendors are out of scope. GEA-7014 stands. Re-plan without R3."

  setup_all do
    Ecto.Migrator.run(Repo, Path.expand("../../priv/repo/migrations", __DIR__), :up, all: true, log: false)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM plan_dispatches")
    Repo.query!("DELETE FROM plans")
    Repo.query!("DELETE FROM issue_parks")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  defp issue, do: %{id: "issue-uuid-rp", identifier: "SYM-RP", title: "Vendor notices", description: "Narrowed body"}

  defp stored_plan(generated_at) do
    {:ok, plan} =
      Planning.upsert_plan(%{
        issue_id: "issue-uuid-rp",
        issue_identifier: "SYM-RP",
        status: "dispatching",
        metadata: %{"generated_at" => DateTime.to_iso8601(generated_at)},
        plan_json: %{
          "rows" => [
            %{"id" => "R1", "description" => "Email notice", "state" => "done", "rationale" => "shipped in abc123"},
            %{"id" => "R2", "description" => "Notice log", "state" => "missing"},
            %{"id" => "R3", "description" => "Vendor SMS for phone-only vendors", "state" => "missing"}
          ]
        }
      })

    plan
  end

  # The Planner, answering as a model would after reading the owner's comment: it drops
  # R3 and returns R1 as `missing`, which the carry-over must not believe.
  defp replan_request(test_pid) do
    fn _system, user_prompt ->
      send(test_pid, {:planner_prompt, user_prompt})

      {:ok,
       %{
         "rows" => [
           %{"id" => "R1", "description" => "Email notice", "state" => "missing"},
           %{"id" => "R2", "description" => "Notice log", "state" => "missing"}
         ],
         "out_of_scope" => []
       }}
    end
  end

  defp comments_fun(parked_at) do
    fn "issue-uuid-rp" ->
      [
        %{body: "Old context from before the park", author: "Owner", created_at: DateTime.add(parked_at, -60, :second)},
        %{body: @answer, author: "Owner", created_at: DateTime.add(parked_at, 60, :second)}
      ]
    end
  end

  test "a release after a park re-plans from the answer, drops the ruled-out row and keeps done rows" do
    stored_plan(DateTime.add(DateTime.utc_now(), -3600, :second))
    {:ok, park} = History.record_park("SYM-RP", "R3 needs a human ruling")

    opts = [request_fun: replan_request(self()), comments_fun: comments_fun(park.inserted_at)]

    assert {:ok, {:has_open_rows, plan, open}} = PlanningWorkflow.assess(issue(), opts)

    assert Enum.map(Plan.rows(plan), & &1["id"]) == ["R1", "R2"]
    assert %{"state" => "done", "rationale" => "shipped in abc123"} = Enum.find(Plan.rows(plan), &(&1["id"] == "R1"))
    assert Enum.map(open, & &1["id"]) == ["R2"]

    assert_received {:planner_prompt, prompt}
    assert prompt =~ @answer
    assert prompt =~ "Vendor SMS for phone-only vendors"
    refute prompt =~ "Old context from before the park"

    # The stored plan is the new one, and the re-plan happens once per release.
    assert %Plan{metadata: %{"replanned_after_park" => _}} = stored = Planning.get_plan_by_issue("SYM-RP")
    assert Enum.map(Plan.rows(stored), & &1["id"]) == ["R1", "R2"]

    assert {:ok, {:has_open_rows, _plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    refute_received {:planner_prompt, _}
  end

  test "a plan made after the last park is kept" do
    {:ok, _park} = History.record_park("SYM-RP", "earlier park")
    stored_plan(DateTime.add(DateTime.utc_now(), 60, :second))

    opts = [request_fun: replan_request(self()), comments_fun: fn _ -> flunk("no re-plan expected") end]

    assert {:ok, {:has_open_rows, plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    assert Enum.map(Plan.rows(plan), & &1["id"]) == ["R1", "R2", "R3"]
    refute_received {:planner_prompt, _}
  end

  test "an issue never parked keeps its plan" do
    stored_plan(DateTime.add(DateTime.utc_now(), -3600, :second))

    opts = [request_fun: replan_request(self()), comments_fun: fn _ -> flunk("no re-plan expected") end]

    assert {:ok, {:has_open_rows, plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    assert length(Plan.rows(plan)) == 3
    refute_received {:planner_prompt, _}
  end

  describe "Planner.keep_done_rows/2" do
    test "without a prior plan the new rows stand as the model wrote them" do
      json = %{"rows" => [%{"id" => "R1", "description" => "d", "state" => "missing"}]}
      assert Planner.keep_done_rows(json, nil) == json
    end
  end
end
