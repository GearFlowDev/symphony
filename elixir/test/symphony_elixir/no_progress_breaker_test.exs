defmodule SymphonyElixir.NoProgressBreakerTest do
  # GEA-10667: GEA-10457 and GEA-10646 parked with every row done, a green PR and
  # `untested`. Review passes at an unchanged head and the Tester's first dispatch
  # read as one state, so the Tester's dispatch was the third repeat and tripped
  # the breaker. The Tester never ran.
  use SymphonyElixir.TestSupport
  @moduletag :planning

  alias SymphonyElixir.History
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Planning
  alias SymphonyElixir.Repo

  setup_all do
    Ecto.Migrator.run(Repo, Path.expand("../../priv/repo/migrations", __DIR__), :up, all: true, log: false)
    :ok
  end

  setup do
    for table <- ~w(plan_dispatches plans run_events runs tester_verdicts issue_parks) do
      Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  defp all_done_plan(identifier) do
    {:ok, plan} =
      Planning.upsert_plan(%{
        issue_id: "issue-uuid-#{identifier}",
        issue_identifier: identifier,
        status: "dispatching",
        metadata: %{},
        plan_json: %{
          "rows" => [
            %{"id" => "R1", "description" => "Landing", "state" => "done"},
            %{"id" => "R2", "description" => "Tests", "state" => "done"}
          ]
        }
      })

    plan
  end

  # The breaker counts a state only once a run has finished since its last count.
  defp finish_a_run(identifier) do
    {:ok, run} =
      History.record_dispatch(%{
        issue_id: "issue-uuid-#{identifier}",
        issue_identifier: identifier,
        issue_title: "Fix the thing",
        started_at: DateTime.utc_now(),
        agent_backend: "claude",
        filter_source: "filter"
      })

    {:ok, _} = History.record_completion(run, %{finished_at: DateTime.utc_now(), outcome: "completed"})
  end

  defp decide(identifier, phase) do
    finish_a_run(identifier)
    Orchestrator.no_progress_check_for_test(%{identifier: identifier}, {:dispatch, %{retask_phases: [phase]}})
  end

  test "a plan with every row done and no Tester verdict dispatches the Tester once" do
    all_done_plan("SYM-TESTONCE")

    assert {:dispatch, _} = decide("SYM-TESTONCE", "Resolve Review")
    assert {:dispatch, _} = decide("SYM-TESTONCE", "Resolve Review")
    assert {:dispatch, %{retask_phases: ["Test"]}} = decide("SYM-TESTONCE", "Test")
  end

  test "a review pass repeated at the same state still trips the breaker" do
    all_done_plan("SYM-REVIEWLOOP")

    assert {:dispatch, _} = decide("SYM-REVIEWLOOP", "Resolve Review")
    assert {:dispatch, _} = decide("SYM-REVIEWLOOP", "Resolve Review")
    assert {:blocked, {:no_progress, message}} = decide("SYM-REVIEWLOOP", "Resolve Review")

    assert message =~ "next=Resolve Review"
    assert message =~ "the tester has not run yet"
  end

  test "a Tester that keeps ending with no verdict trips the breaker and is named" do
    all_done_plan("SYM-NOVERDICT")

    assert {:dispatch, _} = decide("SYM-NOVERDICT", "Test")
    assert {:dispatch, _} = decide("SYM-NOVERDICT", "Test")
    assert {:blocked, {:no_progress, message}} = decide("SYM-NOVERDICT", "Test")

    assert message =~ "next=Test"
    assert message =~ "the tester was dispatched and recorded no verdict"
    refute message =~ "the tester has not run yet"
  end
end
