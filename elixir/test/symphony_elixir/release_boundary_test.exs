defmodule SymphonyElixir.ReleaseBoundaryTest do
  # GEA-10531: a person moved GEA-10455 out of Shaping, the ship gate opened its PR, and
  # two seconds later Symphony parked it again on the previous day's BLOCKED verdict, at
  # the same commit. A park ends a release; nothing the tester said before it gates the
  # next one.
  use ExUnit.Case, async: false

  alias SymphonyElixir.History
  alias SymphonyElixir.History.TesterVerdict
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Repo

  setup_all do
    Ecto.Migrator.run(Repo, Path.expand("../../priv/repo/migrations", __DIR__), :up, all: true, log: false)
    :ok
  end

  setup do
    Repo.query!("DELETE FROM tester_verdicts")
    Repo.query!("DELETE FROM issue_parks")
    :ok
  end

  describe "History.latest_tester_verdict/1" do
    test "a verdict from before the last park does not count" do
      {:ok, _} = History.record_tester_verdict("SYM-REL", "BLOCKED", "43ca70d3", "branch not pushed")
      assert %TesterVerdict{verdict: "BLOCKED"} = History.latest_tester_verdict("SYM-REL")

      {:ok, _} = History.record_park("SYM-REL", "tester BLOCKED")

      assert History.latest_tester_verdict("SYM-REL") == nil
    end

    test "a verdict after the park counts, and the same verdict at the same commit is recorded anew" do
      {:ok, old} = History.record_tester_verdict("SYM-REL", "BLOCKED", "43ca70d3")
      {:ok, _} = History.record_park("SYM-REL")

      # The re-observation guard compares against the current release only. Against the
      # old row it would drop this verdict, and the gate would re-test forever.
      {:ok, new} = History.record_tester_verdict("SYM-REL", "BLOCKED", "43ca70d3")

      refute new.id == old.id
      assert History.latest_tester_verdict("SYM-REL").id == new.id
    end

    test "a park on one issue leaves another issue's verdict alone" do
      {:ok, _} = History.record_tester_verdict("SYM-OTHER", "APPROVE", "abc")
      {:ok, _} = History.record_park("SYM-REL")

      assert %TesterVerdict{verdict: "APPROVE"} = History.latest_tester_verdict("SYM-OTHER")
    end
  end

  describe "History.last_parked_at/1" do
    test "is nil for an issue never parked, and the newest park otherwise" do
      assert History.last_parked_at("SYM-REL") == nil

      {:ok, _} = History.record_park("SYM-REL")
      {:ok, second} = History.record_park("SYM-REL")

      assert %DateTime{} = parked_at = History.last_parked_at("SYM-REL")
      assert DateTime.compare(parked_at, second.inserted_at) == :eq
    end
  end

  describe "Orchestrator.latest_tester_report/2" do
    test "a Linear tester report from before the park does not count" do
      parked_at = ~U[2026-09-25 12:00:00Z]
      old = %{body: "## Tester Report\nRecommendation: APPROVE", created_at: ~U[2026-09-24 21:52:46Z]}

      assert Orchestrator.latest_tester_report([old], parked_at) == nil
      assert Orchestrator.latest_tester_report([old], nil) == old

      new = %{old | created_at: ~U[2026-09-25 13:00:00Z]}
      assert Orchestrator.latest_tester_report([old, new], parked_at) == new
    end
  end

  describe "Orchestrator.still_blocked/3" do
    test "an issue the poll no longer sees active leaves the set; an active one stays" do
      active = MapSet.new(["todo", "in progress"])
      blocked = MapSet.new(["parked-id", "still-active-id"])

      issues = [
        %Issue{id: "still-active-id", identifier: "SYM-1", state: "Todo"},
        %Issue{id: "other-id", identifier: "SYM-2", state: "In Progress"}
      ]

      assert Orchestrator.still_blocked(blocked, issues, active) == MapSet.new(["still-active-id"])
    end

    test "an issue fetched in a parked state leaves the set" do
      active = MapSet.new(["todo"])
      issues = [%Issue{id: "parked-id", identifier: "SYM-1", state: "Shaping"}]

      assert Orchestrator.still_blocked(MapSet.new(["parked-id"]), issues, active) == MapSet.new()
    end
  end

  test "both park points record the park, and only a real park" do
    # Pinned against the source: the two park paths need Linear, a plan store and a
    # running worker. A park that is not recorded lets the old verdict gate the release;
    # one recorded while the issue stays active drops the verdict of a live release; and
    # a parked issue in the sticky set is not dispatched when a person releases it.
    src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))

    assert src =~ "parked? = move_blocked_issue_to_needs_human_state(issue, Config.escalation_needs_human_state()) == :moved"
    assert src =~ "if parked?, do: record_park(issue.identifier, message)"
    assert src =~ "state = if parked?, do: state, else: %{state | blocked: MapSet.put(state.blocked, issue.id)}"

    assert src =~
             "if move_issue_to_needs_human_state(issue_id, identifier, Config.escalation_needs_human_state()) == :moved,\n          do: record_park(identifier, message)"
  end
end
