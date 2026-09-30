defmodule SymphonyElixir.CiSettledTest do
  # GEA-10755: a pending check counted as a pass, so GEA-10458 was handed off six minutes
  # after a push and the harness refused it on checks twice. A Fix CI push also made the
  # tester's APPROVE stale, so every red check cost a full Test run (five on GEA-10458).
  use ExUnit.Case, async: true

  alias SymphonyElixir.{CiSettled, Orchestrator}

  @pr {"o/r", "7"}
  @head "0c6cc513c1a5abeb5b426031e57f9729bae407c4"
  @now ~U[2026-09-30 15:00:00Z]

  defp row(name, state), do: %{"name" => name, "state" => state, "link" => "https://github.com/o/r/actions/runs/1/job/2"}

  defp runs(pairs),
    do: {Jason.encode!(%{"workflow_runs" => Enum.map(pairs, fn {name, status} -> %{"name" => name, "status" => status} end)}), 0}

  # The default world: every run on the head has completed, and the head is an hour old.
  defp gh(overrides \\ %{}) do
    world =
      Map.merge(
        %{runs: runs([{"CI", "completed"}]), committed: {"2026-09-30T14:00:00Z\n", 0}},
        overrides
      )

    fn
      ["api", "repos/o/r/actions/runs?head_sha=" <> _] -> world.runs
      ["api", "repos/o/r/commits/" <> _, "-q", ".commit.committer.date"] -> world.committed
      args -> {"not stubbed: #{inspect(args)}", 1}
    end
  end

  describe "a check that has not finished is a wait" do
    test "every pending state gh reports keeps the issue waiting" do
      for state <- CiSettled.pending_states() do
        assert {:pending, reason} = CiSettled.check(@pr, @head, [row("test (1)", "SUCCESS"), row("test (2)", state)], gh(), @now)
        assert reason =~ "test (2) still running on 0c6cc513c1a5"
      end
    end

    test "a queued workflow run with no check rows yet is a wait, not a clean sweep" do
      gh = gh(%{runs: runs([{"CI", "completed"}, {"Verify", "queued"}])})

      assert {:pending, reason} = CiSettled.check(@pr, @head, [row("lint", "SUCCESS")], gh, @now)
      assert reason =~ "workflow run Verify not completed"
    end

    test "a head with no check at all waits while it is young" do
      gh = gh(%{runs: runs([]), committed: {"2026-09-30T14:55:00Z\n", 0}})

      assert {:pending, reason} = CiSettled.check(@pr, @head, [], gh, @now)
      assert reason =~ "no check has registered"
    end
  end

  describe "a head whose checks have all finished is settled" do
    test "green and red rows alike: a red check is the ship gate's call, not this one" do
      checks = [row("test (1)", "SUCCESS"), row("test (2)", "FAILURE"), row("docs", "SKIPPED")]

      assert CiSettled.check(@pr, @head, checks, gh(), @now) == :settled
    end

    test "a head with no check after the grace is a repo without CI" do
      assert CiSettled.check(@pr, @head, [], gh(%{runs: runs([])}), @now) == :settled
    end

    test "a gh read that fails is skipped, so a transient error never wedges a finished issue" do
      gh = gh(%{runs: {"HTTP 502", 1}, committed: {"HTTP 502", 1}})

      assert CiSettled.check(@pr, @head, [], gh, @now) == :settled
      assert CiSettled.check(@pr, "?", [], gh(%{runs: runs([])}), @now) == :settled
    end
  end

  test "the tester's APPROVE reaches :done only through CiSettled" do
    # Pinned against the source: complete_tester_action/4 needs Linear, gh and a plan
    # store. Dropping the wait hands off with CI pending again (GEA-10458).
    src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))

    assert src =~ ~r/:approved ->\n\s+case ci_settled\(pr_url\) do\n\s+:settled -> :done\n\s+\{:pending, reason\} -> \{:wait, /
    assert src =~ "CiSettled.check(pr, full_head_sha(pr), checks, &gh_cmd/1)"
  end

  describe "last_code_change_at/1: a Fix CI push does not make the tester's verdict stale" do
    defp dispatch(finished_at, phase \\ nil) do
      rows = %{"rows" => [%{"id" => "R1"}]}
      %{role: "implement", finished_at: finished_at, assigned_rows_json: if(phase, do: Map.put(rows, "phase", phase), else: rows)}
    end

    test "the newest finished Implement is the clock" do
      assert Orchestrator.last_code_change_at([dispatch(~U[2026-09-29 10:00:00Z]), dispatch(~U[2026-09-29 12:00:00Z], "Implement")]) ==
               ~U[2026-09-29 12:00:00Z]
    end

    test "a later Fix CI does not move it" do
      assert Orchestrator.last_code_change_at([dispatch(~U[2026-09-29 10:00:00Z], "Implement"), dispatch(~U[2026-09-29 16:00:00Z], "Fix CI")]) ==
               ~U[2026-09-29 10:00:00Z]
    end

    test "a Fix CI alone, a Test, and a run still going leave no clock" do
      assert Orchestrator.last_code_change_at([
               dispatch(~U[2026-09-29 16:00:00Z], "Fix CI"),
               %{role: "test", finished_at: ~U[2026-09-29 17:00:00Z], assigned_rows_json: %{}},
               dispatch(nil, "Implement")
             ]) == nil
    end

    test "the Fix CI phase is recorded on its Dispatch" do
      src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))
      workflow = File.read!(Path.expand("../../lib/symphony_elixir/planning/workflow.ex", __DIR__))

      assert src =~ "PlanningWorkflow.start_implement_dispatch(plan, rows, phase: phase)"
      assert src =~ ~s|reopen_and_dispatch(issue, metadata, plan, reason, "Fix CI")|
      assert workflow =~ ~s|%{"rows" => rows, "phase" => phase}|
    end
  end
end
