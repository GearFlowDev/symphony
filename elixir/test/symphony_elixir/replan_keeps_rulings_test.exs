defmodule SymphonyElixir.ReplanKeepsRulingsTest do
  # GEA-10756: on GEA-10457 a person's ruling removed rows R4-R6 (the location, vendor
  # and contact pickers). The ruling came before the last park, so the re-plan after the
  # release never saw it, and the body's picker list brought R4-R6 back. The run parked
  # for a person again.
  use SymphonyElixir.TestSupport
  @moduletag :planning

  alias SymphonyElixir.History
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Planner}
  alias SymphonyElixir.Planning.Workflow, as: PlanningWorkflow
  alias SymphonyElixir.Repo

  @ruling "Scope: the unit and job pickers only. Drop R4, R5 and R6."

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

  defp issue, do: %{id: "issue-uuid-rk", identifier: "SYM-RK", title: "Pickers", description: "Every picker creates from typed text"}

  defp row(id, desc, state \\ "missing"), do: %{"id" => id, "description" => desc, "state" => state}

  defp body_rows do
    [
      row("R1", "Shared create affordance"),
      row("R2", "Unit picker creates"),
      row("R3", "Job picker creates"),
      row("R4", "Location picker creates"),
      row("R5", "Vendor picker creates"),
      row("R6", "Contact picker creates")
    ]
  end

  defp stored_plan(generated_at) do
    {:ok, plan} =
      Planning.upsert_plan(%{
        issue_id: "issue-uuid-rk",
        issue_identifier: "SYM-RK",
        status: "dispatching",
        metadata: %{"generated_at" => DateTime.to_iso8601(generated_at)},
        plan_json: %{"rows" => List.update_at(body_rows(), 0, &Map.put(&1, "state", "done"))}
      })

    plan
  end

  # A model that follows the ruling when it sees it, and otherwise plans every row the
  # body asks for.
  defp planner(test_pid) do
    fn _system, user_prompt ->
      send(test_pid, {:planner_prompt, user_prompt})
      rows = if user_prompt =~ @ruling, do: Enum.take(body_rows(), 3), else: body_rows()
      {:ok, %{"rows" => rows, "out_of_scope" => []}}
    end
  end

  defp comment(body, at), do: %{body: body, author: "Owner", created_at: at}

  defp ids(plan), do: Enum.map(Plan.rows(plan), & &1["id"])

  test "a ruling posted before the last park reaches the re-plan" do
    now = DateTime.utc_now()
    stored_plan(DateTime.add(now, -3 * 3600, :second))
    ruling = comment(@ruling, DateTime.add(now, -2 * 3600, :second))
    {:ok, _park} = History.record_park("SYM-RK", "a later park on a grader loop")

    opts = [request_fun: planner(self()), comments_fun: fn "issue-uuid-rk" -> {:ok, [ruling]} end]

    assert {:ok, {:has_open_rows, plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    assert ids(plan) == ["R1", "R2", "R3"]
    assert_received {:planner_prompt, prompt}
    assert prompt =~ @ruling
  end

  test "a second release keeps the rows the first re-plan removed, though the body still asks for them" do
    now = DateTime.utc_now()
    stored_plan(DateTime.add(now, -3 * 3600, :second))
    ruling = comment(@ruling, DateTime.add(now, -2 * 3600, :second))
    {:ok, _first_park} = History.record_park("SYM-RK", "R6 needs a human ruling")
    first = [ruling]

    opts = [request_fun: planner(self()), comments_fun: fn "issue-uuid-rk" -> {:ok, first} end]
    assert {:ok, {:has_open_rows, _plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    assert_received {:planner_prompt, _}

    # The first re-plan's plan is newer than the first park. Park again, later, and
    # release with only a retask since then: the ruling is older than the prior plan.
    replanned = Planning.get_plan_by_issue("SYM-RK")
    assert ids(replanned) == ["R1", "R2", "R3"]
    assert Enum.map(replanned.plan_json["out_of_scope"], & &1["id"]) == ["R4", "R5", "R6"]

    Repo.query!("UPDATE issue_parks SET inserted_at = $1", [DateTime.add(now, 60, :second)])
    retask = comment("The judge returned RETASK: add the job dialog.", DateTime.add(now, 120, :second))
    opts = [request_fun: planner(self()), comments_fun: fn "issue-uuid-rk" -> {:ok, first ++ [retask]} end]

    assert {:ok, {:has_open_rows, plan, open}} = PlanningWorkflow.assess(issue(), opts)

    assert_received {:planner_prompt, prompt}
    refute prompt =~ @ruling
    assert prompt =~ "Rows an earlier ruling removed"
    assert prompt =~ "Contact picker creates"

    assert ids(plan) == ["R1", "R2", "R3"]
    assert Enum.map(open, & &1["id"]) == ["R2", "R3"]
    assert Enum.map(plan.plan_json["out_of_scope"], & &1["id"]) == ["R4", "R5", "R6"]
    assert ids(Planning.get_plan_by_issue("SYM-RK")) == ["R1", "R2", "R3"]
  end

  test "a fresh plan reads a ruling posted before it" do
    ruling = comment(@ruling, DateTime.add(DateTime.utc_now(), -60, :second))

    opts = [
      request_fun: planner(self()),
      comments_fun: fn "issue-uuid-rk" -> {:ok, [ruling]} end,
      audit_fun: fn _issue, _identifier, _opts -> nil end
    ]

    assert {:ok, {:has_open_rows, plan, _open}} = PlanningWorkflow.assess(issue(), opts)
    assert ids(plan) == ["R1", "R2", "R3"]
    assert_received {:planner_prompt, prompt}
    assert prompt =~ "Comments on the issue"
    assert prompt =~ @ruling
  end

  test "a fresh plan defers on a failed comment read" do
    opts = [
      request_fun: planner(self()),
      comments_fun: fn _ -> {:error, :timeout} end,
      audit_fun: fn _issue, _identifier, _opts -> flunk("no audit expected") end
    ]

    assert {:error, {:comments_unavailable, :timeout} = reason} = PlanningWorkflow.assess(issue(), opts)
    assert SymphonyElixir.Orchestrator.transient_plan_failure?({:plan_assess_failed, reason})
    assert Planning.get_plan_by_issue("SYM-RK") == nil
    refute_received {:planner_prompt, _}
  end

  describe "Planner.keep_removed_rows/2" do
    test "without a prior plan the new rows stand as the model wrote them" do
      json = %{"rows" => [row("R1", "d")]}
      assert Planner.keep_removed_rows(json, nil) == json
    end

    test "keeps the model's own out_of_scope entries, bare strings too" do
      prior = %Plan{issue_identifier: "SYM-RK", plan_json: %{"rows" => [row("R1", "a"), row("R2", "b")], "out_of_scope" => ["a note"]}}
      json = %{"rows" => [row("R1", "a")], "out_of_scope" => ["a note", %{"id" => "X1", "description" => "trimmed"}]}

      result = Planner.keep_removed_rows(json, prior)
      assert result["rows"] == [row("R1", "a")]
      assert [%{"id" => "R2", "state" => "deferred"}, "a note", %{"id" => "X1"}] = result["out_of_scope"]
    end
  end
end
