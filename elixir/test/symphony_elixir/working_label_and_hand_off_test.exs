defmodule SymphonyElixir.WorkingLabelAndHandOffTest do
  @moduledoc """
  The two marks and the one ending a Symphony run has (GEA-9888):

  * `symphony-working` goes on the issue at claim and comes off at every ending,
    mirroring the agent pool's `auto-working`.
  * A run ends at a ready pull request, and under a grant that hands off, at the
    hand-off command. It never ends at a draft.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLabelClient do
    @moduledoc false
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :results}) do
        [result | rest] ->
          Process.put({__MODULE__, :results}, rest)
          result

        _ ->
          {:error, :no_result_configured}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLabelClient)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end
    end)

    :ok
  end

  defp lookup_response(nodes, team_id \\ "team-gea") do
    {:ok,
     %{
       "data" => %{
         "issue" => %{"team" => %{"id" => team_id}},
         "issueLabels" => %{"nodes" => nodes}
       }
     }}
  end

  test "adding the label resolves the issue's own team's label and mutates with its id" do
    Process.put(
      {FakeLabelClient, :results},
      [
        lookup_response([%{"id" => "label-1", "team" => %{"id" => "team-gea"}}]),
        {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.add_label("issue-1", "symphony-working")

    assert_receive {:graphql_called, lookup, %{issueId: "issue-1", name: "symphony-working"}}
    assert lookup =~ "issueLabels"
    assert_receive {:graphql_called, mutation, %{issueId: "issue-1", labelId: "label-1"}}
    assert mutation =~ "issueAddLabel"
  end

  test "another team's same-named label is never adopted; a workspace-level one is" do
    # Label names collide across teams. Adopting a stranger's label would make
    # this box's live-run marker something the other team's board wears, and this
    # orchestrator would then retract it from their issues.
    Process.put(
      {FakeLabelClient, :results},
      [
        lookup_response([
          %{"id" => "other-team", "team" => %{"id" => "team-xyz"}},
          %{"id" => "workspace-wide", "team" => nil}
        ]),
        {:ok, %{"data" => %{"issueRemoveLabel" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.remove_label("issue-1", "symphony-working")

    assert_receive {:graphql_called, _lookup, _vars}
    assert_receive {:graphql_called, mutation, %{labelId: "workspace-wide"}}
    assert mutation =~ "issueRemoveLabel"
  end

  test "a name no label answers to is an error the caller can log, not a crash" do
    Process.put({FakeLabelClient, :results}, [lookup_response([])])
    assert {:error, :label_not_found} = Adapter.add_label("issue-1", "no-such-label")

    Process.put({FakeLabelClient, :results}, [{:error, :boom}])
    assert {:error, :boom} = Adapter.add_label("issue-1", "symphony-working")
  end

  test "a mutation Linear refuses is reported, not swallowed" do
    Process.put(
      {FakeLabelClient, :results},
      [
        lookup_response([%{"id" => "label-1", "team" => %{"id" => "team-gea"}}]),
        {:ok, %{"data" => %{"issueAddLabel" => %{"success" => false}}}}
      ]
    )

    assert {:error, :label_update_failed} = Adapter.add_label("issue-1", "symphony-working")

    Process.put(
      {FakeLabelClient, :results},
      [
        lookup_response([%{"id" => "label-1", "team" => %{"id" => "team-gea"}}]),
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :label_update_failed} = Adapter.remove_label("issue-1", "symphony-working")
  end

  test "the memory tracker records both label writes" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok = Memory.add_label("issue-1", "symphony-working")
    assert_receive {:memory_tracker_label_add, "issue-1", "symphony-working"}

    assert :ok = Memory.remove_label("issue-1", "symphony-working")
    assert_receive {:memory_tracker_label_remove, "issue-1", "symphony-working"}
  end

  test "the working label and the hand-off command are read from the workflow file" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_working_label: "symphony-working",
      hand_off_command: "bin/linear handoff \"$SYMPHONY_ISSUE_IDENTIFIER\" \"$SYMPHONY_PR_URL\"",
      escalation_needs_human_state: "Shaping"
    )

    assert Config.tracker_working_label() == "symphony-working"
    assert Config.hand_off_command() =~ "$SYMPHONY_PR_URL"
    assert Config.hand_off_timeout_ms() > 0
    assert Config.escalation_needs_human_state() == "Shaping"
  end

  test "both are absent by default, and absence leaves the board unmarked" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.tracker_working_label() == nil
    assert Config.hand_off_command() == nil
  end

  describe "the live mark comes off when the run ends" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_working_label: "symphony-working"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      :ok
    end

    defp running_state(issue_id) do
      agent =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent,
            ref: nil,
            identifier: "GEA-1",
            issue: %Issue{id: issue_id, state: "In Progress", identifier: "GEA-1"},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }
    end

    test "a person moving the issue out of an active state ends the run and unmarks it" do
      state = running_state("issue-ended")

      issue = %Issue{
        id: "issue-ended",
        identifier: "GEA-1",
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: ["auto-symphony"]
      }

      Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert_receive {:memory_tracker_label_remove, "issue-ended", "symphony-working"}, 1_000
    end

    test "a stall keeps the mark on, because a retry follows it" do
      # `:stalled` is the one termination reason a retry follows. Dropping the
      # label there would leave the retried run unmarked on the board for the
      # rest of its life.
      Orchestrator.terminate_running_issue_for_test(running_state("issue-stalled"), "issue-stalled", false, :stalled)

      refute_receive {:memory_tracker_label_remove, "issue-stalled", _}, 300
    end

    test "every other reason drops it, including one added later" do
      for reason <- [:terminal_state, :not_routable, :non_active_state, :dashboard_stopped, :label_removed] do
        issue_id = "issue-#{reason}"

        Orchestrator.terminate_running_issue_for_test(running_state(issue_id), issue_id, false, reason)

        assert_receive {:memory_tracker_label_remove, ^issue_id, "symphony-working"}, 1_000
      end
    end

    test "no label is configured, so nothing is written" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      Orchestrator.terminate_running_issue_for_test(running_state("issue-plain"), "issue-plain", false, :terminal_state)

      refute_receive {:memory_tracker_label_remove, "issue-plain", _}, 300
    end
  end
end
