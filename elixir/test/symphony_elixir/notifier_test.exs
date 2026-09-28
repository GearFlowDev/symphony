defmodule SymphonyElixir.NotifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Notifier

  @moduletag :notifier

  describe "format_linear_comment/2" do
    test "max_continuations_exhausted includes missing phases" do
      comment =
        Notifier.format_linear_comment(:max_continuations_exhausted, %{
          missing_phases: ["Test", "Share Evidence"],
          continuation_count: 5
        })

      assert comment =~ "Agent Gave Up"
      assert comment =~ "5 continuation"
      assert comment =~ "Test, Share Evidence"
    end

    test "max_failure_retries_exhausted includes attempt count" do
      comment =
        Notifier.format_linear_comment(:max_failure_retries_exhausted, %{
          attempt: 3,
          max_retries: 3
        })

      assert comment =~ "Max Retries"
      assert comment =~ "3/3"
    end

    test "low_eval_score includes score, threshold, and failing checks" do
      comment =
        Notifier.format_linear_comment(:low_eval_score, %{
          score: 35,
          threshold: 60,
          failing_checks: ["CI not passed", "No tests written"]
        })

      assert comment =~ "35/100"
      assert comment =~ "threshold: 60"
      assert comment =~ "CI not passed"
      assert comment =~ "No tests written"
    end

    test "agent_stalled includes reason" do
      comment =
        Notifier.format_linear_comment(:agent_stalled, %{
          stall_reason: "stalled for 600000ms without codex activity"
        })

      assert comment =~ "Stalled"
      assert comment =~ "600000ms"
    end

    test "needs_human includes help message" do
      comment =
        Notifier.format_linear_comment(:needs_human, %{
          help_message: "I cannot find the database migration for this table"
        })

      assert comment =~ "## Ask:"
      assert comment =~ "cannot find the database migration"
    end

    test "needs_human is a decision card: goal, status, problem, recommendation, ask, in that order (GEA-10619)" do
      comment =
        Notifier.format_linear_comment(:needs_human, %{
          identifier: "GEA-1",
          title: "Sort import events",
          source: :agent,
          parked_state: "Shaping",
          help_message: "The Stripe test key is missing from the slot. Ask: Add the key to the box, or drop the payment rows? Recommend: Add the key; the rows are the point of the issue."
        })

      positions =
        for field <- ["**Goal.**", "**Status.**", "**Problem.**", "**Recommendation.**", "**Ask.**"] do
          {at, _} = :binary.match(comment, field)
          at
        end

      assert positions == Enum.sort(positions)
      assert comment =~ ~s(## Ask: Add the key to the box, or drop the payment rows?)
      assert comment =~ ~s(GEA-1 "Sort import events")
      assert comment =~ "The Stripe test key is missing from the slot."
      assert comment =~ "**Recommendation.** Add the key; the rows are the point of the issue."
      assert comment =~ "parked GEA-1 in Shaping"
      assert comment =~ "Default: none. GEA-1 stays in Shaping until a person moves it. Door: one-way."
      refute comment =~ "provide guidance"
    end

    test "a bare agent message and an orchestrator park still get a full card, marked as Symphony's recommendation" do
      agent = Notifier.format_linear_comment(:needs_human, %{identifier: "GEA-1", source: :agent, help_message: "no Linear key"})
      assert agent =~ "**Recommendation.** (Symphony's, the agent gave none.)"
      assert agent =~ "no Linear key"

      park =
        Notifier.format_linear_comment(:needs_human, %{
          identifier: "GEA-2",
          help_message: "the dispatch cycle has returned to the same state 3× (limit 3)"
        })

      assert park =~ "**Problem.** Symphony cannot advance the run: the dispatch cycle"
      assert park =~ "**Recommendation.** (Symphony's.)"
      assert park =~ "Door: one-way."
    end
  end

  describe "notify_sync/3" do
    test "calls comment_fn for actionable events (low_eval_score)" do
      test_pid = self()

      comment_fn = fn issue_id, body ->
        send(test_pid, {:comment, issue_id, body})
        :ok
      end

      Notifier.notify_sync(
        :low_eval_score,
        %{
          issue_id: "issue-123",
          identifier: "GEA-456",
          score: 40,
          threshold: 60,
          failing_checks: ["Tests"]
        },
        comment_fn: comment_fn
      )

      assert_received {:comment, "issue-123", body}
      assert body =~ "Low Quality Score"
      assert body =~ "Tests"
    end

    test "skips comment for operational events (stalled, max retries)" do
      test_pid = self()

      comment_fn = fn id, body ->
        send(test_pid, {:comment, id, body})
        :ok
      end

      Notifier.notify_sync(
        :agent_stalled,
        %{issue_id: "issue-789", identifier: "GEA-101", stall_reason: "phase stuck"},
        comment_fn: comment_fn
      )

      refute_received {:comment, _, _}

      Notifier.notify_sync(
        :max_failure_retries_exhausted,
        %{issue_id: "issue-789", identifier: "GEA-101", attempt: 4, max_retries: 3},
        comment_fn: comment_fn
      )

      refute_received {:comment, _, _}
    end

    test "calls webhook_fn when webhook URL is configured" do
      test_pid = self()

      comment_fn = fn id, body ->
        send(test_pid, {:comment, id, body})
        :ok
      end

      webhook_fn = fn url, payload ->
        send(test_pid, {:webhook, url, payload})
        :ok
      end

      # Use needs_human which still posts comments
      Notifier.notify_sync(
        :needs_human,
        %{
          issue_id: "issue-789",
          identifier: "GEA-101",
          help_message: "stuck on auth"
        },
        comment_fn: comment_fn,
        webhook_fn: webhook_fn,
        project_fn: fn _ -> {:ok, nil} end
      )

      assert_received {:comment, "issue-789", body}
      assert body =~ "## Ask:"
    end

    test "skips comment when issue_id is nil" do
      test_pid = self()

      comment_fn = fn _id, _body ->
        send(test_pid, :comment_called)
        :ok
      end

      Notifier.notify_sync(
        :agent_stalled,
        %{identifier: "GEA-101", stall_reason: "stuck"},
        comment_fn: comment_fn
      )

      refute_received :comment_called
    end

    test "needs_human posts the card on the project thread and one pointer on the issue (GEA-10619)" do
      test_pid = self()
      comment_fn = fn id, body -> send(test_pid, {:comment, id, body}) && :ok end
      project_fn = fn "issue-1" -> {:ok, %{id: "proj-1", name: "Harness board", url: "https://linear.app/p/harness"}} end
      project_comment_fn = fn id, body -> send(test_pid, {:project_comment, id, body}) && :ok end

      Notifier.notify_sync(
        :needs_human,
        %{issue_id: "issue-1", identifier: "GEA-1", source: :agent, help_message: "stuck"},
        comment_fn: comment_fn,
        project_fn: project_fn,
        project_comment_fn: project_comment_fn
      )

      assert_received {:project_comment, "proj-1", card}
      assert card =~ "## Ask:"
      assert_received {:comment, "issue-1", pointer}
      assert pointer =~ "[Harness board](https://linear.app/p/harness)"
      refute pointer =~ "## Ask:"
      refute_received {:comment, _, _}
    end

    test "needs_human posts the card on the issue when it has no project, or the project post fails" do
      test_pid = self()
      comment_fn = fn id, body -> send(test_pid, {:comment, id, body}) && :ok end
      project_comment_fn = fn id, body -> send(test_pid, {:project_comment, id, body}) && :ok end

      for {project_fn, pc_fn} <- [
            {fn _ -> {:ok, nil} end, project_comment_fn},
            {fn _ -> {:error, :timeout} end, project_comment_fn},
            {fn _ -> raise "boom" end, project_comment_fn},
            {fn _ -> {:ok, %{id: "proj-1", name: "B", url: nil}} end, fn _, _ -> {:error, :rate_limited} end}
          ] do
        Notifier.notify_sync(
          :needs_human,
          %{issue_id: "issue-2", identifier: "GEA-2", help_message: "stuck"},
          comment_fn: comment_fn,
          project_fn: project_fn,
          project_comment_fn: pc_fn
        )

        assert_received {:comment, "issue-2", card}
        assert card =~ "## Ask:"
        refute_received {:project_comment, _, _}
      end
    end

    test "handles comment_fn errors without crashing" do
      comment_fn = fn _id, _body -> {:error, :api_down} end

      # Should not raise
      Notifier.notify_sync(
        :needs_human,
        %{issue_id: "issue-123", help_message: "stuck"},
        comment_fn: comment_fn,
        project_fn: fn _ -> {:ok, nil} end
      )
    end

    test "handles comment_fn exceptions without crashing" do
      comment_fn = fn _id, _body -> raise "boom" end

      # Should not raise
      Notifier.notify_sync(
        :needs_human,
        %{issue_id: "issue-123", help_message: "stuck"},
        comment_fn: comment_fn,
        project_fn: fn _ -> {:ok, nil} end
      )
    end
  end
end
