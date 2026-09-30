defmodule SymphonyElixir.NoProgressBreakerTest do
  # GEA-10667: GEA-10457 and GEA-10646 parked with every row done, a green PR and
  # `untested`. Review passes at an unchanged head and the Tester's first dispatch
  # read as one state, so the Tester's dispatch was the third repeat and tripped
  # the breaker. The Tester never ran.
  use SymphonyElixir.TestSupport
  @moduletag :planning

  alias SymphonyElixir.Config
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
    assert message =~ "the tester was dispatched and recorded no new verdict"
    refute message =~ "the tester has not run yet"
  end

  # A verdict from an older head makes tester_gate ask for a new Test. It must
  # not turn the message back into "plan, grader and tester are not converging".
  test "a stale verdict does not hide a Tester that keeps ending with no new verdict" do
    all_done_plan("SYM-STALE")
    {:ok, _} = History.record_tester_verdict("SYM-STALE", "REQUEST_CHANGES", "abc1234", "old head")

    assert {:dispatch, _} = decide("SYM-STALE", "Test")
    assert {:dispatch, _} = decide("SYM-STALE", "Test")
    assert {:blocked, {:no_progress, message}} = decide("SYM-STALE", "Test")

    assert message =~ "the tester was dispatched and recorded no new verdict"
    refute message =~ "not converging"
  end

  # GEA-10753: GEA-10457's two Resolve Review runs died with `:not_found` before
  # their first turn, and each one counted as a cycle. The breaker parked a green,
  # clean PR two minutes later.
  describe "a run that crashed before its first turn" do
    defp crash_a_run(identifier) do
      {:ok, run} =
        History.record_dispatch(%{
          issue_id: "issue-uuid-#{identifier}",
          issue_identifier: identifier,
          issue_title: "Fix the thing",
          started_at: DateTime.utc_now(),
          agent_backend: "claude",
          filter_source: "filter"
        })

      {:ok, _} = History.record_completion(run, %{finished_at: DateTime.utc_now(), outcome: "failed", turns_used: 0})
    end

    defp decide_after_crash(identifier, phase) do
      crash_a_run(identifier)
      Orchestrator.no_progress_check_for_test(%{identifier: identifier}, {:dispatch, %{retask_phases: [phase]}})
    end

    test "does not count toward the breaker" do
      all_done_plan("SYM-CRASH")

      assert {:dispatch, _} = decide("SYM-CRASH", "Resolve Review")
      assert {:dispatch, _} = decide_after_crash("SYM-CRASH", "Resolve Review")
      assert {:dispatch, _} = decide_after_crash("SYM-CRASH", "Resolve Review")
      assert {:dispatch, _} = decide("SYM-CRASH", "Resolve Review")
    end

    test "is the only failed run the breaker skips" do
      crash_a_run("SYM-CRASH-COUNT")
      assert History.finished_run_count("SYM-CRASH-COUNT") == 0

      {:ok, run} =
        History.record_dispatch(%{
          issue_id: "issue-uuid-SYM-CRASH-COUNT",
          issue_identifier: "SYM-CRASH-COUNT",
          issue_title: "Fix the thing",
          started_at: DateTime.utc_now(),
          agent_backend: "claude",
          filter_source: "filter"
        })

      {:ok, _} = History.record_completion(run, %{finished_at: DateTime.utc_now(), outcome: "failed", turns_used: 3})
      assert History.finished_run_count("SYM-CRASH-COUNT") == 1

      finish_a_run("SYM-CRASH-COUNT")
      assert History.finished_run_count("SYM-CRASH-COUNT") == 2
    end

    # The Claude runner counts only completed turns, so a run that failed during
    # its first turn has zero turns. Its session proves the agent ran.
    test "a run that failed during its first turn still counts" do
      {:ok, run} =
        History.record_dispatch(%{
          issue_id: "issue-uuid-SYM-TURN1",
          issue_identifier: "SYM-TURN1",
          issue_title: "Fix the thing",
          started_at: DateTime.utc_now(),
          agent_backend: "claude",
          filter_source: "filter"
        })

      {:ok, _} =
        History.record_completion(run, %{
          finished_at: DateTime.utc_now(),
          outcome: "failed",
          session_id: "claude-session-1",
          turns_used: 0
        })

      assert History.finished_run_count("SYM-TURN1") == 1
    end
  end

  # GEA-10753: GEA-10458's tester approved on the day's twelfth run, and the
  # budget, checked before the decision, parked the finished issue with no hand-off.
  describe "the daily dispatch budget" do
    defp spend_the_budget(identifier) do
      for _ <- 1..Config.max_dispatches_per_issue_per_day() do
        {:ok, run} =
          History.record_dispatch(%{
            issue_id: "issue-uuid-#{identifier}",
            issue_identifier: identifier,
            issue_title: "Fix the thing",
            started_at: DateTime.utc_now(),
            agent_backend: "claude",
            filter_source: "filter"
          })

        {:ok, _} =
          History.record_completion(run, %{
            finished_at: DateTime.utc_now(),
            outcome: "completed",
            session_id: "thread-#{run.id}",
            turns_used: 2
          })
      end
    end

    test "never blocks a finished issue" do
      spend_the_budget("SYM-BUDGET-DONE")

      assert :done = Orchestrator.guard_decision_for_test(%{identifier: "SYM-BUDGET-DONE"}, :done)
    end

    test "still blocks one more dispatch" do
      spend_the_budget("SYM-BUDGET-MORE")

      assert {:blocked, {:dispatch_budget_exhausted, _}} =
               Orchestrator.guard_decision_for_test(
                 %{identifier: "SYM-BUDGET-MORE"},
                 {:dispatch, %{retask_phases: ["Implement"]}}
               )
    end
  end

  test "a row the grader keeps open parks with that row named as the question" do
    {:ok, _} =
      Planning.upsert_plan(%{
        issue_id: "issue-uuid-SYM-STUCKROW",
        issue_identifier: "SYM-STUCKROW",
        status: "dispatching",
        metadata: %{},
        plan_json: %{
          "rows" => [
            %{"id" => "R1", "description" => "Prompt", "state" => "done"},
            %{"id" => "R8", "description" => "Run it green", "state" => "partial", "rationale" => "no green-run evidence"}
          ]
        }
      })

    assert {:dispatch, _} = decide("SYM-STUCKROW", "Implement")
    assert {:dispatch, _} = decide("SYM-STUCKROW", "Implement")
    assert {:blocked, {:no_progress, message}} = decide("SYM-STUCKROW", "Implement")

    assert message =~ "next=Implement"
    assert message =~ "The grader keeps 1 row(s) open: R8 (partial): no green-run evidence."
  end
end
