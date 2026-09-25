defmodule SymphonyElixir.ShipGateTest do
  # GEA-10495: a complete plan with no PR used to pass every ship gate vacuously, so the
  # tester was sent to check a branch origin had never seen (GEA-10455). The ship gate
  # pushes the graded rows and opens the PR first, and a failure parks the issue with
  # git's own words instead.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator

  describe "ship_verdict/2" do
    test "a push that fails blocks with git's words, whatever a PR lookup said" do
      assert Orchestrator.ship_verdict({:error, "git push of b failed: mix: not found"}, nil) ==
               {:blocked, {:push_failed, "git push of b failed: mix: not found"}}

      assert {:blocked, {:push_failed, _}} = Orchestrator.ship_verdict({:error, "x"}, "https://github.com/o/r/pull/1")
    end

    test "a pushed branch with a PR goes on to the gates at that PR" do
      url = "https://github.com/o/r/pull/7"

      assert Orchestrator.ship_verdict({:ok, :pushed}, url) == {:ok, url}
      assert Orchestrator.ship_verdict(:ok, url) == {:ok, url}
    end

    test "a pushed branch with no PR blocks: the tester never runs against nothing" do
      assert {:blocked, {:no_pr, reason}} = Orchestrator.ship_verdict({:ok, :pushed}, nil)
      assert reason =~ "no PR could be opened"
    end
  end

  test "the ship gate runs before the external gates and the tester" do
    # Pinned against the source because complete_plan_action/3 needs Linear, gh and a
    # plan store. Moving the gate after external_ship_gate/1 reopens GEA-10455.
    src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))
    [_, after_feedback] = String.split(src, "defp complete_plan_action(issue, metadata, plan) do", parts: 2)
    [body, _] = String.split(after_feedback, "\n  defp ", parts: 2)

    assert body =~ "ship_gate(issue, metadata)"
    refute body =~ "external_ship_gate("
    assert src =~ "Evaluator.ensure_pushed(slot_dir, branch)"
  end
end
