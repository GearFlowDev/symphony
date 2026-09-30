defmodule SymphonyElixir.ProofEvidenceTest do
  # GEA-10667: rows that ask for proof (a green run, a CodeRabbit review,
  # screenshots) stayed `partial` on every grade, because the grader saw only
  # the diff and the PR body. GEA-10457 (R10) and GEA-10459 (R8) looped to the
  # no-progress breaker at an unchanged head.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Planning.{Dispatch, Grader, Plan, ProofEvidence}

  @head "a59430d343b8ffffffffffffffffffffffffffff"

  defp pr(overrides \\ %{}) do
    Map.merge(
      %{
        "headRefOid" => @head,
        "statusCheckRollup" => [
          %{"name" => "test (1)", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
          %{"name" => "checks", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
          %{"context" => "CodeRabbit", "state" => "SUCCESS"}
        ],
        "latestReviews" => [
          %{"author" => %{"login" => "coderabbitai"}, "state" => "APPROVED", "commit" => %{"oid" => @head}}
        ],
        "comments" => [
          %{"author" => %{"login" => "gearflow-bot-2"}, "createdAt" => "2026-09-30T12:40:00Z", "body" => "@coderabbitai review"},
          %{"author" => %{"login" => "someone"}, "createdAt" => "2026-09-30T12:41:00Z", "body" => "unrelated"}
        ]
      },
      overrides
    )
  end

  describe "the PR state section" do
    test "a green head with CodeRabbit on the head and no open threads reads as proof" do
      section = ProofEvidence.format_pr_state(pr(), 0)

      assert section =~ "Head: `a59430d343b8`"
      assert section =~ "CI checks on the head: 3 passed, 0 failed, 0 pending."
      assert section =~ "CodeRabbit: latest review is APPROVED on the head."
      assert section =~ "Unresolved review threads: 0."
      assert section =~ "PR comment by gearflow-bot-2 at 2026-09-30T12:40:00Z: `@coderabbitai review`"
      refute section =~ "unrelated"
    end

    test "failed and pending checks are named, and a review on an older commit says so" do
      section =
        ProofEvidence.format_pr_state(
          pr(%{
            "statusCheckRollup" => [
              %{"name" => "test (2)", "status" => "COMPLETED", "conclusion" => "FAILURE"},
              %{"name" => "verify", "status" => "IN_PROGRESS", "conclusion" => nil},
              %{"context" => "ci/legacy", "state" => "PENDING"}
            ],
            "latestReviews" => [
              %{"author" => %{"login" => "coderabbitai"}, "state" => "CHANGES_REQUESTED", "commit" => %{"oid" => "8d9c8cd8aaaa0000"}}
            ]
          }),
          2
        )

      assert section =~ "0 passed, 1 failed (test (2)), 2 pending (verify, ci/legacy)."
      assert section =~ "CodeRabbit: latest review is CHANGES_REQUESTED on `8d9c8cd8aaaa`, not the head."
      assert section =~ "Unresolved review threads: 2."
    end

    test "reads the PR through gh, and a gh failure gives no section" do
      gh = fn
        ["pr", "view", "4054", "--repo", "GearFlowDev/gf_procurement" | _] -> {Jason.encode!(pr()), 0}
        ["api", "graphql" | _] -> {"1\n", 0}
      end

      section = ProofEvidence.pr_state_section("https://github.com/GearFlowDev/gf_procurement/pull/4054", gh)
      assert section =~ "Unresolved review threads: 1."

      assert ProofEvidence.pr_state_section("https://github.com/GearFlowDev/gf_procurement/pull/4054", fn _ -> {"boom", 1} end) ==
               nil

      assert ProofEvidence.pr_state_section(nil) == nil
    end
  end

  describe "the issue comments section" do
    @since ~U[2026-09-30 12:00:00Z]

    test "keeps the comments posted during the dispatch and counts their images" do
      comments = [
        %{body: "old plan", author: "auto", created_at: ~U[2026-09-30 11:00:00Z]},
        %{
          body: "## Tester Report\n![job dialog](https://uploads.linear.app/a.png)\n![unit row](https://uploads.linear.app/b.png)",
          author: "automation",
          created_at: ~U[2026-09-30 12:30:00Z]
        }
      ]

      section = ProofEvidence.issue_comments_section(comments, @since)

      assert section =~ "### automation at 2026-09-30T12:30:00Z (images: 2)"
      refute section =~ "old plan"
    end

    test "no comment in the window, or an unreadable thread, gives no section" do
      assert ProofEvidence.issue_comments_section([%{body: "x", author: "a", created_at: ~U[2026-09-30 11:00:00Z]}], @since) ==
               nil

      assert ProofEvidence.issue_comments_for("issue-1", @since, fn _ -> {:error, :down} end) == nil
      assert ProofEvidence.issue_comments_for(nil, @since, fn _ -> flunk("must not read") end) == nil
    end
  end

  describe "the grader" do
    test "puts the proof sections in its prompt" do
      dispatch = %Dispatch{assigned_rows_json: %{"rows" => [%{"id" => "R10", "state" => "partial"}]}}
      plan = %Plan{plan_json: %{"rows" => [%{"id" => "R10", "state" => "partial"}]}}

      prompt =
        Grader.build_user_prompt(dispatch, plan,
          diff: "stat",
          pr_state: ProofEvidence.format_pr_state(pr(), 0),
          issue_comments: "## Issue comments during this dispatch (live from Linear)\n\nx"
        )

      assert prompt =~ "## PR state on the head (live from GitHub)"
      assert prompt =~ "## Issue comments during this dispatch (live from Linear)"
    end

    test "grades screenshots to the Test phase and green runs from CI" do
      assert Grader.system_prompt() =~ "Proof rows are graded from the proof channels"
      assert Grader.system_prompt() =~ "screenshots fall to the Test"
      assert Grader.system_prompt() =~ "every CI check on the head passed"
    end
  end

  describe "a breaker park on open rows" do
    test "names each open row and the grader's reason as one question" do
      plan = %Plan{
        plan_json: %{
          "rows" => [
            %{"id" => "R7", "state" => "done", "rationale" => "fine"},
            %{"id" => "R8", "state" => "partial", "rationale" => "The test output section is empty,\n so there is no green-run evidence."}
          ]
        }
      }

      question = Orchestrator.open_rows_question(plan)

      assert question =~ "The grader keeps 1 row(s) open: R8 (partial): The test output section is empty, so there is no green-run evidence."
      assert question =~ "decide: close it, drop it, or say what proof counts"
      refute question =~ "R7"
    end

    test "adds nothing when every row is done" do
      assert Orchestrator.open_rows_question(%Plan{plan_json: %{"rows" => [%{"id" => "R1", "state" => "done"}]}}) == ""
    end
  end
end
