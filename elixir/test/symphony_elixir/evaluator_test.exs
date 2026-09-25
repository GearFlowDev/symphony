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

    test "a PR left as a draft is finished rather than left unmergeable" do
      # Pinned against the source because this arm needs a real `gh` and a real PR, which
      # a unit test has neither of. Both strings are commands: deleting either reds this.
      #
      # WHY THE ARM EXISTS. Nothing promotes a draft any more — the promotion step went with
      # the drafts — so a draft left by an older image would sit for ever, and
      # `gh pr view --json mergeable` reports a draft as MERGEABLE, so nothing downstream
      # would notice.
      src = File.read!(Path.expand("../../lib/symphony_elixir/evaluator.ex", __DIR__))

      assert src =~ "--json url,number,state,isDraft", "check_pr no longer asks whether the PR is a draft"
      assert src =~ "gh pr ready ", "a draft PR is no longer made ready"
    end

    test "a blank or missing branch name is not a PR to open" do
      assert Evaluator.ensure_pr_open("/tmp", "", "GEA-1: x", "Linear: GEA-1") == nil
      assert Evaluator.ensure_pr_open("/tmp", nil, "GEA-1: x", "Linear: GEA-1") == nil
    end
  end

  describe "ensure_pushed/2" do
    # GEA-10495: GEA-10455's worker committed and never pushed, the grader marked every row
    # done from the slot's local diff, and the tester was sent to a PR that did not exist.
    # The orchestrator now pushes graded rows itself. These run real git against a bare
    # origin, with a pre-push hook that always fails: a product slot's hook dies with
    # `mix: not found` on the Symphony box, and the push must not depend on it.

    @git_env [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]

    setup do
      root = Path.join(System.tmp_dir!(), "symphony-push-#{System.unique_integer([:positive])}")
      origin = Path.join(root, "origin.git")
      slot = Path.join(root, "slot")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      git!(root, ["init", "--quiet", "--bare", "--initial-branch=main", origin])
      git!(root, ["clone", "--quiet", origin, slot])
      git!(slot, ["checkout", "--quiet", "-b", "main"])
      commit!(slot, "base")
      git!(slot, ["push", "--quiet", "origin", "main"])
      # The slot's shape on the box: origin's main only, so no remote-tracking ref exists
      # for the issue branch.
      git!(slot, ["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
      git!(slot, ["checkout", "--quiet", "-b", "gea-1-work"])
      commit!(slot, "R1")

      hook = Path.join([slot, ".git", "hooks", "pre-push"])
      File.write!(hook, "#!/bin/sh\necho 'mix: not found' >&2\nexit 127\n")
      File.chmod!(hook, 0o755)

      %{root: root, origin: origin, slot: slot}
    end

    test "an unpushed branch is pushed past a failing pre-push hook", %{origin: origin, slot: slot} do
      head = git!(slot, ["rev-parse", "HEAD"])

      assert Evaluator.ensure_pushed(slot, "gea-1-work") == {:ok, :pushed}
      assert git!(origin, ["rev-parse", "refs/heads/gea-1-work"]) == head
    end

    test "a branch origin already holds is left alone", %{slot: slot} do
      git!(slot, ["push", "--quiet", "--no-verify", "origin", "gea-1-work"])

      assert Evaluator.ensure_pushed(slot, "gea-1-work") == :ok
    end

    test "origin ahead of the slot is not an error: it already holds the work", %{root: root, origin: origin, slot: slot} do
      git!(slot, ["push", "--quiet", "--no-verify", "origin", "gea-1-work"])
      other = Path.join(root, "other")
      git!(root, ["clone", "--quiet", "--branch", "gea-1-work", origin, other])
      commit!(other, "a person's fix on top")
      git!(other, ["push", "--quiet", "origin", "gea-1-work"])

      assert Evaluator.ensure_pushed(slot, "gea-1-work") == :ok
    end

    test "a diverged branch is an error carrying git's words, never a force push", %{root: root, origin: origin, slot: slot} do
      git!(slot, ["push", "--quiet", "--no-verify", "origin", "gea-1-work"])
      other = Path.join(root, "other")
      git!(root, ["clone", "--quiet", "--branch", "gea-1-work", origin, other])
      commit!(other, "theirs")
      git!(other, ["push", "--quiet", "origin", "gea-1-work"])
      theirs = git!(origin, ["rev-parse", "refs/heads/gea-1-work"])
      commit!(slot, "ours")

      assert {:error, reason} = Evaluator.ensure_pushed(slot, "gea-1-work")
      assert reason =~ "git push of gea-1-work failed"
      assert reason =~ "rejected"
      assert git!(origin, ["rev-parse", "refs/heads/gea-1-work"]) == theirs
    end

    test "a branch the slot does not have is an error, not a push", %{origin: origin, slot: slot} do
      assert {:error, reason} = Evaluator.ensure_pushed(slot, "gea-2-never-made")
      assert reason =~ "does not exist"
      assert {_, 128} = System.cmd("git", ["rev-parse", "--verify", "refs/heads/gea-2-never-made"], cd: origin, stderr_to_stdout: true)
    end

    test "no slot or no branch is an error and no crash" do
      assert {:error, _} = Evaluator.ensure_pushed(nil, "gea-1-work")
      assert {:error, _} = Evaluator.ensure_pushed("/tmp", "")
      assert {:error, _} = Evaluator.ensure_pushed("/tmp", nil)
    end

    defp git!(dir, args) do
      {out, 0} = System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true)
      String.trim(out)
    end

    defp commit!(dir, message) do
      git!(dir, ["commit", "--quiet", "--allow-empty", "-m", message])
    end
  end

  describe "branch_pr_state/2" do
    test "no slot or no branch is an error and no crash" do
      assert {:error, _} = Evaluator.branch_pr_state(nil, "gea-1-work")
      assert {:error, _} = Evaluator.branch_pr_state("/tmp", "")
    end
  end
end
