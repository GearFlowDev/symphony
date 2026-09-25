defmodule SymphonyElixir.TrackerCoverageTest do
  @moduledoc """
  Routes every Tracker write through the memory adapter and checks the event it
  reports.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  test "the memory tracker kind selects the memory adapter" do
    assert Tracker.adapter() == Memory
  end

  test "writes are relayed as memory tracker events" do
    assert {:ok, "memory-comment-i-1"} = Tracker.create_comment_with_id("i-1", "hello")
    assert_received {:memory_tracker_comment, "i-1", "hello"}

    assert :ok = Tracker.update_comment("c-1", "edited")
    assert_received {:memory_tracker_comment_update, "c-1", "edited"}

    assert :ok = Tracker.claim_issue("i-1", "In Progress")
    assert_received {:memory_tracker_claim, "i-1", "In Progress"}

    assert :ok = Tracker.add_label("i-1", "working")
    assert_received {:memory_tracker_label_add, "i-1", "working"}

    assert :ok = Tracker.remove_label("i-1", "working")
    assert_received {:memory_tracker_label_remove, "i-1", "working"}

    assert :ok = Tracker.update_issue_state("i-1", "Done")
    assert_received {:memory_tracker_state_update, "i-1", "Done"}
  end

  test "writes are silent without a recipient" do
    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.add_label("i-1", "x")
    refute_received {:memory_tracker_label_add, _, _}
  end

  test "state filtering ignores non-issue entries and nil states" do
    issues = [
      %Issue{id: "a", state: " In Progress "},
      %Issue{id: "b", state: nil},
      %{id: "not-an-issue", state: "In Progress"}
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    assert {:ok, [%Issue{id: "a"}]} = Tracker.fetch_issues_by_states(["in progress"])
    assert {:ok, [%Issue{id: "b"}]} = Tracker.fetch_issue_states_by_ids(["b", "zz"])
    assert {:ok, [%Issue{id: "a"}, %Issue{id: "b"}]} = Tracker.fetch_candidate_issues()
  end
end
