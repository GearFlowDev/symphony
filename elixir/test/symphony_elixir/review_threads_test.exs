defmodule SymphonyElixir.ReviewThreadsTest do
  # GEA-10826: every unresolved thread counted as work, so a thread that carried the
  # worker's reply sent a Resolve Review to the same head on every poll. GEA-10677 got
  # three in six minutes and parked, while CodeRabbit was still reading the reply.
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Orchestrator, ReviewThreads}

  @pr {"o/r", "7"}
  @now ~U[2026-09-30 22:13:00Z]

  defp thread(reviewer, last_author, last_at, resolved \\ false) do
    %{
      "isResolved" => resolved,
      "first" => %{"nodes" => [%{"author" => %{"login" => reviewer}}]},
      "last" => %{"nodes" => [%{"author" => %{"login" => last_author}, "createdAt" => last_at}]}
    }
  end

  defp gh(threads, status \\ 0) do
    body = Jason.encode!(%{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => threads}}}}})

    fn
      ["api", "graphql", "-f", "query=" <> _] -> {body, status}
      args -> {"not stubbed: #{inspect(args)}", 1}
    end
  end

  describe "classify/2" do
    test "a thread whose last word is the reviewer's is a worker's to answer" do
      assert %{ours: 1, theirs: 0} =
               ReviewThreads.classify([thread("coderabbitai", "coderabbitai", "2026-09-30T21:56:06Z")], @now)
    end

    test "a fresh reply the reviewer has not answered is the reviewer's move" do
      # GEA-10677 at the park: the worker replied at 22:12:19Z, CodeRabbit resolved at 22:18Z.
      assert %{ours: 0, theirs: 1} =
               ReviewThreads.classify([thread("coderabbitai", "gearflow-bot-2", "2026-09-30T22:12:19Z")], @now)
    end

    test "a reply the reviewer left unanswered past the grace goes back to a worker" do
      stale = DateTime.add(@now, -ReviewThreads.reply_grace_seconds(), :second) |> DateTime.to_iso8601()

      assert %{ours: 1, theirs: 0} = ReviewThreads.classify([thread("coderabbitai", "gearflow-bot-2", stale)], @now)
    end

    test "a resolved thread counts for nobody" do
      assert %{ours: 0, theirs: 0} =
               ReviewThreads.classify([thread("coderabbitai", "coderabbitai", "2026-09-30T22:00:00Z", true)], @now)
    end

    test "a thread with no readable authors is a worker's, never a silent wait" do
      assert %{ours: 1, theirs: 0} = ReviewThreads.classify([%{"isResolved" => false}], @now)
    end

    test "threads are tallied one by one" do
      threads = [
        thread("coderabbitai", "gearflow-bot-2", "2026-09-30T22:10:00Z"),
        thread("coderabbitai", "coderabbitai", "2026-09-30T22:11:00Z"),
        thread("a-person", "gearflow-bot-2", "2026-09-30T22:12:00Z")
      ]

      assert %{ours: 1, theirs: 2} = ReviewThreads.classify(threads, @now)
    end
  end

  describe "snapshot/3" do
    test "reads the threads from the graphql answer" do
      assert %{ours: 0, theirs: 1} =
               ReviewThreads.snapshot(@pr, gh([thread("coderabbitai", "gearflow-bot-2", "2026-09-30T22:12:19Z")]), @now)
    end

    test "a gh read that fails counts no thread" do
      assert %{ours: 0, theirs: 0} = ReviewThreads.snapshot(@pr, gh([], 1), @now)
      assert %{ours: 0, theirs: 0} = ReviewThreads.snapshot(@pr, fn _ -> {"not json", 0} end, @now)
    end
  end

  describe "the review gate's verdict" do
    test "only threads the reviewer owes make a wait, not a Resolve Review" do
      assert {:review_wait, reason} = Orchestrator.review_verdict(%{}, %{ours: 0, theirs: 1})
      assert reason =~ "1 review threads"
    end

    test "a thread a worker owes dispatches, even beside threads the reviewer owes" do
      assert {:request_changes, reason} = Orchestrator.review_verdict(%{}, %{ours: 1, theirs: 2})
      assert reason =~ "1 unresolved review threads"
    end

    test "a pending reply outranks a requested-changes review: the reviewer answers first" do
      coderabbit = %{"latestReviews" => [%{"author" => %{"login" => "coderabbitai"}, "state" => "CHANGES_REQUESTED"}]}

      assert {:review_wait, _} = Orchestrator.review_verdict(coderabbit, %{ours: 0, theirs: 1})
      assert {:request_changes, _} = Orchestrator.review_verdict(coderabbit, %{ours: 0, theirs: 0})
      assert {:request_changes, _} = Orchestrator.review_verdict(%{"reviewDecision" => "CHANGES_REQUESTED"}, %{ours: 0, theirs: 0})
    end

    test "no open thread and no requested changes passes" do
      assert :ok = Orchestrator.review_verdict(%{"reviewDecision" => "", "latestReviews" => []}, %{ours: 0, theirs: 0})
    end

    test "a review wait becomes a wait for the orchestrator, and CI is read before it" do
      source = File.read!("lib/symphony_elixir/orchestrator.ex")

      assert source =~ ~r/\{:review_wait, reason\} ->\s*(#[^\n]*\n\s*)*\{:wait, reason\}/
      assert source =~ ~r/:ok <- ci_gate\(issue, plan, pr_url\) do\s*review_gate\(pr_url\)/
    end
  end
end
