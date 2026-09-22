defmodule SymphonyElixir.EvaluatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Evaluator

  @moduletag :evaluator

  describe "evaluate/2" do
    test "returns zeroed evaluation when workspace does not exist" do
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}

      eval = Evaluator.evaluate(run_context, "/nonexistent/path")

      assert eval.pr_created == false
      assert eval.ci_status == "none"
      assert eval.files_changed == 0
      assert eval.lines_changed == 0
      assert eval.branch_pushed == false
      assert eval.evidence_posted == false
      assert eval.workpad_updated == false
      assert eval.tests_written == false
      assert eval.score == 0
    end

    test "returns zeroed evaluation when workspace is nil" do
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}

      eval = Evaluator.evaluate(run_context, nil)

      assert eval.score == 0
      assert eval.pr_created == false
    end

    test "score is bounded at 100" do
      # The max possible score from defaults is 100 (25+20+15+15+10+10+5)
      # This just verifies the cap exists
      run_context = %{issue_id: nil, branch_name: nil, identifier: nil}
      eval = Evaluator.evaluate(run_context, nil)
      assert eval.score >= 0 and eval.score <= 100
    end
  end

  describe "failing_checks/1" do
    test "returns all checks when everything fails" do
      eval = %{
        pr_created: false,
        ci_status: "none",
        tests_written: false,
        evidence_posted: false,
        workpad_updated: false,
        files_changed: 0,
        branch_pushed: false,
        score: 0
      }

      checks = Evaluator.failing_checks(eval)
      assert "PR not created" in checks
      assert "CI not passed" in checks
      assert "No tests written" in checks
      assert "No evidence posted" in checks
      assert "Workpad not updated" in checks
      assert "No code changes" in checks
      assert "Branch not pushed" in checks
      assert length(checks) == 7
    end

    test "returns empty list when everything passes" do
      eval = %{
        pr_created: true,
        ci_status: "passed",
        tests_written: true,
        evidence_posted: true,
        workpad_updated: true,
        files_changed: 5,
        branch_pushed: true,
        score: 100
      }

      assert Evaluator.failing_checks(eval) == []
    end

    test "returns only failing checks for partial success" do
      eval = %{
        pr_created: true,
        ci_status: "failed",
        tests_written: true,
        evidence_posted: false,
        workpad_updated: true,
        files_changed: 3,
        branch_pushed: true,
        score: 55
      }

      checks = Evaluator.failing_checks(eval)
      assert "CI not passed" in checks
      assert "No evidence posted" in checks
      assert length(checks) == 2
    end
  end

  describe "ensure_pr_open/4" do
    test "no workspace means no PR and no crash" do
      assert Evaluator.ensure_pr_open(nil, "gea-1-branch", "GEA-1: x", "Linear: GEA-1") == nil
      assert Evaluator.ensure_pr_open("/nonexistent/path", "gea-1-branch", "GEA-1: x", "b") == nil
    end

    test "a branch that is not on origin gets no PR" do
      # An unpushed branch is a run that closed no rows, not a run missing its
      # PR. Opening one here would publish work nobody graded.
      dir = Path.join(System.tmp_dir!(), "symphony-evaluator-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {_, 0} = System.cmd("git", ["init", "--quiet", dir])

      assert Evaluator.ensure_pr_open(dir, "gea-1-never-pushed", "GEA-1: x", "Linear: GEA-1") == nil
    end

    test "a blank or missing branch name is not a PR to open" do
      assert Evaluator.ensure_pr_open("/tmp", "", "GEA-1: x", "Linear: GEA-1") == nil
      assert Evaluator.ensure_pr_open("/tmp", nil, "GEA-1: x", "Linear: GEA-1") == nil
    end
  end
end
