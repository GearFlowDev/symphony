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

  describe "Orchestrator.still_blocked/4" do
    @active MapSet.new(["todo", "in progress"])

    test "a candidate still active keeps its block; one seen parked loses it" do
      issues = [
        %Issue{id: "active-id", identifier: "SYM-1", state: "Todo"},
        %Issue{id: "parked-id", identifier: "SYM-2", state: "Shaping"}
      ]

      fetcher = fn _ -> flunk("every blocked issue was seen; nothing to fetch") end

      assert Orchestrator.still_blocked(MapSet.new(["active-id", "parked-id"]), issues, @active, fetcher) ==
               MapSet.new(["active-id"])
    end

    test "an issue missing from the candidates is read by ID, and loses its block only when inactive" do
      # The candidate query filters on the routing label: an issue that lost it is
      # absent but still active, and still in its release.
      fetcher = fn ids ->
        assert Enum.sort(ids) == ["label-gone-id", "parked-id"]

        {:ok,
         [
           %Issue{id: "label-gone-id", identifier: "SYM-1", state: "In Progress"},
           %Issue{id: "parked-id", identifier: "SYM-2", state: "Shaping"}
         ]}
      end

      assert Orchestrator.still_blocked(MapSet.new(["label-gone-id", "parked-id"]), [], @active, fetcher) ==
               MapSet.new(["label-gone-id"])
    end

    test "a failed read keeps every unseen block" do
      blocked = MapSet.new(["a", "b"])
      assert Orchestrator.still_blocked(blocked, [], @active, fn _ -> {:error, :timeout} end) == blocked
    end
  end

  describe "the park decision" do
    test "a successful move records the park and leaves the issue out of the sticky set" do
      {:ok, _} = History.record_tester_verdict("SYM-PARK", "BLOCKED", "43ca70d3")
      state = Orchestrator.settle_park(%Orchestrator.State{}, %{id: "id-1", identifier: "SYM-PARK"}, "tester BLOCKED", :moved)

      assert %DateTime{} = History.last_parked_at("SYM-PARK")
      assert History.latest_tester_verdict("SYM-PARK") == nil
      refute MapSet.member?(state.blocked, "id-1")
    end

    test "a failed move records no park, keeps the verdict, and marks the issue sticky" do
      {:ok, _} = History.record_tester_verdict("SYM-PARK", "BLOCKED", "43ca70d3")
      state = Orchestrator.settle_park(%Orchestrator.State{}, %{id: "id-1", identifier: "SYM-PARK"}, "tester BLOCKED", :not_moved)

      assert History.last_parked_at("SYM-PARK") == nil
      assert %TesterVerdict{verdict: "BLOCKED"} = History.latest_tester_verdict("SYM-PARK")
      assert MapSet.member?(state.blocked, "id-1")
    end

    test "the agent-escalation path records a park only on a successful move" do
      assert Orchestrator.record_park_if_moved(:not_moved, "SYM-HELP", "needs help") == :not_parked
      assert History.last_parked_at("SYM-HELP") == nil

      assert Orchestrator.record_park_if_moved(:moved, "SYM-HELP", "needs help") == :parked
      assert %DateTime{} = History.last_parked_at("SYM-HELP")
    end
  end

  test "both park points go through the park decision" do
    # The paths themselves need Linear, the notifier, gh and a running worker; the
    # decision they share is tested above. This pins that they still share it.
    src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))

    assert src =~ "|> settle_park(issue, message, move_result)"
    assert src =~ "|> record_park_if_moved(identifier, message)"
  end
end
