defmodule SymphonyElixir.Linear.AdapterCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter

  @uuid "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  # Answers each graphql call with the next scripted response (in the calling
  # process's dictionary) and reports the call back to the test process.
  defmodule ScriptedClient do
    @moduledoc false
    def graphql(query, variables) do
      send(self(), {:graphql, query, variables})

      case Process.get(:responses, []) do
        [next | rest] ->
          Process.put(:responses, rest)
          next

        [] ->
          raise "no scripted response left for #{inspect(variables)}"
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_env = System.get_env("LINEAR_CLAIM_ASSIGNEE")
    System.delete_env("LINEAR_CLAIM_ASSIGNEE")
    Application.put_env(:symphony_elixir, :linear_client_module, ScriptedClient)

    on_exit(fn ->
      restore_env("LINEAR_CLAIM_ASSIGNEE", previous_env)

      if previous,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    :ok
  end

  defp script(responses), do: Process.put(:responses, responses)
  defp ok(data), do: {:ok, %{"data" => data}}
  defp state_found, do: ok(%{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-9"}]}}}})

  defp calls do
    Stream.repeatedly(fn ->
      receive do
        {:graphql, query, vars} -> {query, vars}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  describe "create_comment_with_id/2" do
    test "returns the new comment id" do
      script([ok(%{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-1"}}})])
      assert Adapter.create_comment_with_id("issue-1", "hi") == {:ok, "c-1"}
      assert [{query, %{issueId: "issue-1", body: "hi"}}] = calls()
      assert query =~ "SymphonyCreateCommentWithId"
    end

    test "fails when unsuccessful, id-less, or the client errors" do
      script([
        ok(%{"commentCreate" => %{"success" => false}}),
        ok(%{"commentCreate" => %{"success" => true, "comment" => nil}}),
        {:error, :timeout}
      ])

      assert Adapter.create_comment_with_id("i", "b") == {:error, :comment_create_failed}
      assert Adapter.create_comment_with_id("i", "b") == {:error, :comment_create_failed}
      assert Adapter.create_comment_with_id("i", "b") == {:error, :timeout}
    end
  end

  describe "update_comment/2" do
    test "succeeds and reports each failure shape" do
      script([
        ok(%{"commentUpdate" => %{"success" => true}}),
        ok(%{"commentUpdate" => %{"success" => false}}),
        {:error, :http_500},
        ok(%{})
      ])

      assert Adapter.update_comment("c-1", "new") == :ok
      assert Adapter.update_comment("c-1", "new") == {:error, :comment_update_failed}
      assert Adapter.update_comment("c-1", "new") == {:error, :http_500}
      assert Adapter.update_comment("c-1", "new") == {:error, :comment_update_failed}
      assert [{query, %{id: "c-1", body: "new"}} | _] = calls()
      assert query =~ "commentUpdate"
    end
  end

  describe "claim_issue/2" do
    test "assigns to the API viewer when no claim assignee is configured" do
      script([state_found(), ok(%{"viewer" => %{"id" => "bot-1"}}), ok(%{"issueUpdate" => %{"success" => true}})])

      assert Adapter.claim_issue("issue-1", "In Progress") == :ok

      assert [
               {_, %{issueId: "issue-1", stateName: "In Progress"}},
               {viewer_q, %{}},
               {claim_q, %{issueId: "issue-1", stateId: "state-9", assigneeId: "bot-1"}}
             ] = calls()

      assert viewer_q =~ "viewer"
      assert claim_q =~ "SymphonyClaimIssue"
    end

    test "uses a configured UUID assignee without a lookup" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_claim_assignee: @uuid)
      script([state_found(), ok(%{"issueUpdate" => %{"success" => true}})])

      assert Adapter.claim_issue("issue-1", "In Progress") == :ok
      assert [_, {_, %{assigneeId: @uuid}}] = calls()
    end

    test "resolves a configured email to a user id" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_claim_assignee: "dev@example.com")

      script([
        state_found(),
        ok(%{"users" => %{"nodes" => [%{"id" => "user-7"}]}}),
        ok(%{"issueUpdate" => %{"success" => false}})
      ])

      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :issue_update_failed}
      assert [_, {_, %{email: "dev@example.com"}}, {_, %{assigneeId: "user-7"}}] = calls()
    end

    test "an unknown email or failing lookup stops the claim" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_claim_assignee: "ghost@example.com")

      script([state_found(), ok(%{"users" => %{"nodes" => []}})])
      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :assignee_not_found}

      script([state_found(), {:error, :rate_limited}])
      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :rate_limited}
    end

    test "a missing or failing viewer lookup stops the claim" do
      script([state_found(), ok(%{"viewer" => nil})])
      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :viewer_id_not_found}

      script([state_found(), {:error, :down}])
      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :down}
    end

    test "state lookup failures and odd mutation responses" do
      script([ok(%{"issue" => nil})])
      assert Adapter.claim_issue("issue-1", "Nope") == {:error, :state_not_found}

      script([state_found(), ok(%{"viewer" => %{"id" => "bot"}}), ok(%{"issueUpdate" => nil})])
      assert Adapter.claim_issue("issue-1", "In Progress") == {:error, :issue_update_failed}
    end
  end

  describe "add_label/2 and remove_label/2" do
    test "prefer the issue's own team label over a workspace label and another team's" do
      script([
        ok(%{
          "issue" => %{"team" => %{"id" => "team-a"}},
          "issueLabels" => %{
            "nodes" => [
              %{"id" => "other-team", "team" => %{"id" => "team-b"}},
              %{"id" => "workspace", "team" => nil},
              %{"id" => "own", "team" => %{"id" => "team-a"}}
            ]
          }
        }),
        ok(%{"issueAddLabel" => %{"success" => true}})
      ])

      assert Adapter.add_label("issue-1", "symphony-working") == :ok

      assert [{lookup, %{issueId: "issue-1", name: "symphony-working"}}, {add, %{issueId: "issue-1", labelId: "own"}}] =
               calls()

      assert lookup =~ "issueLabels"
      assert add =~ "issueAddLabel"
    end

    test "fall back to the workspace label and never adopt another team's" do
      script([
        ok(%{
          "issue" => %{"team" => %{"id" => "team-a"}},
          "issueLabels" => %{"nodes" => [%{"id" => "other", "team" => %{"id" => "team-b"}}, %{"id" => "ws", "team" => nil}]}
        }),
        ok(%{"issueRemoveLabel" => %{"success" => true}})
      ])

      assert Adapter.remove_label("issue-1", "x") == :ok
      assert [_, {remove, %{labelId: "ws"}}] = calls()
      assert remove =~ "issueRemoveLabel"

      script([
        ok(%{
          "issue" => %{"team" => %{"id" => "team-a"}},
          "issueLabels" => %{"nodes" => [%{"id" => "other", "team" => %{"id" => "team-b"}}]}
        })
      ])

      assert Adapter.add_label("issue-1", "x") == {:error, :label_not_found}
    end

    test "no labels, a lookup error, and failing mutations" do
      script([ok(%{"issue" => nil, "issueLabels" => nil})])
      assert Adapter.add_label("issue-1", "x") == {:error, :label_not_found}

      script([{:error, :boom}])
      assert Adapter.add_label("issue-1", "x") == {:error, :boom}

      label = ok(%{"issue" => nil, "issueLabels" => %{"nodes" => [%{"id" => "ws", "team" => nil}]}})

      script([label, ok(%{"issueAddLabel" => %{"success" => false}})])
      assert Adapter.add_label("issue-1", "x") == {:error, :label_update_failed}

      script([label, {:error, :http}])
      assert Adapter.remove_label("issue-1", "x") == {:error, :http}

      script([label, ok(%{"issueRemoveLabel" => %{"success" => "yes"}})])
      assert Adapter.remove_label("issue-1", "x") == {:error, :label_update_failed}
    end
  end
end
