defmodule SymphonyElixir.CiRecoveryTest do
  # GEA-10757: every red check dispatched Fix CI, and a person re-ran the job or updated
  # the branch by hand four times in two days on gf_procurement: a flaky test in a file
  # the PR did not touch (#4062, #4085), a runner whose Postgres died at setup (#4085),
  # and an advisory main had already fixed (#4001). The job and step shapes below are
  # the ones those runs left behind.
  use ExUnit.Case, async: true

  alias SymphonyElixir.CiRecovery

  @pr {"o/r", "7"}
  @head "0c6cc513c1a5abeb5b426031e57f9729bae407c4"
  @now ~U[2026-09-30 15:00:00Z]

  defp check(name, run_id, job_id),
    do: %{"name" => name, "state" => "FAILURE", "link" => "https://github.com/o/r/actions/runs/#{run_id}/job/#{job_id}"}

  # `gh run view --log` prefixes every line with job, step and timestamp.
  defp log_lines(job, lines),
    do: Enum.map_join(lines, "\n", &"#{job}\tUNKNOWN STEP\t2026-09-29T14:29:03.5598475Z #{&1}")

  defp exunit_failure(path),
    do: ["  1) test a thing happens (Gf.ThingTest)", "     #{path}:1369", "     ** (DBConnection.OwnershipError) cannot find ownership process"]

  defp steps(failed),
    do: Jason.encode!(%{"steps" => [%{"name" => "Checkout", "conclusion" => "success"}, %{"name" => failed, "conclusion" => "failure"}]})

  defp check_runs(pairs),
    do: Jason.encode!(%{"check_runs" => Enum.map(pairs, fn {id, name, c} -> %{"id" => id, "name" => name, "conclusion" => c} end)})

  # The default world: one failed shard whose run has finished, a diff of two files,
  # and a main that has not moved.
  defp world(overrides \\ %{}) do
    Map.merge(
      %{
        {:status, "100"} => {"completed\n", 0},
        {:steps, "900"} => {steps("Elixir Test"), 0},
        {:log, "900"} => {log_lines("test (8)", exunit_failure("test/gf_web/live/inbox_live_test.exs")), 0},
        :diff => {"lib/gf_web/user_auth.ex\ntest/gf_web/user_auth_test.exs\n", 0},
        :default_branch => {"main\n", 0},
        :compare => {Jason.encode!(%{"ahead_by" => 0, "merge_base_commit" => %{"sha" => "base0"}}), 0}
      },
      overrides
    )
  end

  defp gh(world) do
    test = self()

    fn args ->
      key = key(args)
      send(test, {:gh, key})
      Map.get(world, key, {"not stubbed: #{inspect(args)}", 1})
    end
  end

  defp key(["run", "view", "--job", job | _]), do: {:log, job}
  defp key(["run", "view", run | _]), do: {:status, run}
  defp key(["run", "rerun", run | _]), do: {:rerun, run}
  defp key(["pr", "diff" | _]), do: :diff
  defp key(["pr", "update-branch" | _]), do: :update_branch
  defp key(["api", "repos/o/r", "-q", ".default_branch"]), do: :default_branch
  defp key(["api", "repos/o/r/actions/jobs/" <> job]), do: {:steps, job}
  defp key(["api", "repos/o/r/compare/" <> _]), do: :compare
  defp key(["api", "repos/o/r/commits/" <> rest]), do: {:checks, rest |> String.split("/") |> hd()}
  defp key(args), do: {:other, args}

  defp decide(failing, recoveries, world),
    do: CiRecovery.decide(@pr, @head, failing, recoveries, gh(world), @now)

  describe "a failure the diff did not cause is re-run once" do
    test "a flaky test in a file the PR does not touch is re-run, not sent to Fix CI (#4062)" do
      assert {:recover, :rerun, ["100"], reason} = decide([check("test (8)", 100, 900)], [], world())
      assert reason =~ "outside this diff"
      assert reason =~ "`test (8)` failed in `Elixir Test` and names no file of the diff"
    end

    test "a job that died in a setup step is re-run, and the note says it never reached its tests (#4085)" do
      w = world(%{{:steps, "900"} => {steps("Install PDF rasterizer"), 0}, {:log, "900"} => {log_lines("test (1)", [~s(FATAL:  role "root" does not exist)]), 0}})

      assert {:recover, :rerun, ["100"], reason} = decide([check("test (1)", 100, 900)], [], w)
      assert reason =~ "setup step `Install PDF rasterizer`, before its tests ran"
    end

    test "the aggregate gate that fails because a shard failed does not change the verdict" do
      w = world(%{{:steps, "901"} => {steps("Gate on needed jobs"), 0}, {:log, "901"} => {log_lines("verify", ["needed jobs failed"]), 0}})

      assert {:recover, :rerun, ["100"], _} = decide([check("test (8)", 100, 900), check("verify", 100, 901)], [], w)
    end

    test "the re-run runs `gh run rerun --failed` once per run" do
      assert CiRecovery.act(@pr, :rerun, ["100", "101"], gh(%{{:rerun, "100"} => {"", 0}, {:rerun, "101"} => {"", 0}})) == :ok
      assert_received {:gh, {:rerun, "100"}}
      assert_received {:gh, {:rerun, "101"}}
    end

    test "a re-run gh refuses is an error with gh's words, so the gate falls back to Fix CI" do
      assert CiRecovery.act(@pr, :rerun, ["100"], gh(%{{:rerun, "100"} => {"run 100 cannot be rerun\n", 1}})) ==
               {:error, "run 100 cannot be rerun"}
    end
  end

  describe "a failure the diff caused goes straight to Fix CI" do
    test "an ExUnit failure in a test file the diff touches" do
      w = world(%{{:log, "900"} => {log_lines("test (8)", exunit_failure("test/gf_web/user_auth_test.exs")), 0}})

      assert {:fix_ci, reason} = decide([check("test (8)", 100, 900)], [], w)
      assert reason =~ "`test (8)` fails at `test/gf_web/user_auth_test.exs`, a file this diff touches"
      refute_received {:gh, {:steps, _}}
    end

    test "a compiler diagnostic in a lib file the diff touches, with CI's absolute checkout path" do
      line = "    └─ /home/runner/work/r/r/lib/gf_web/user_auth.ex:12:5: GfWeb.UserAuth.fetch/2"
      w = world(%{{:log, "900"} => {log_lines("checks", ["warning: variable \"x\" is unused", line]), 0}})

      assert {:fix_ci, reason} = decide([check("checks", 100, 900)], [], w)
      assert reason =~ "user_auth.ex"
    end

    test "a check that is not a GitHub Actions job cannot be re-run, so it keeps the old answer" do
      failing = [%{"name" => "external-ci", "state" => "FAILURE", "link" => "https://ci.example.com/b/1"}]

      assert {:fix_ci, reason} = decide(failing, [], world())
      assert reason =~ "not a GitHub Actions job"
    end
  end

  describe "a recovery in flight is a wait" do
    test "a failed job whose run is still going waits for the run to finish" do
      assert {:wait, reason} = decide([check("test (8)", 100, 900)], [], world(%{{:status, "100"} => {"in_progress\n", 0}}))
      assert reason =~ "still running"
      refute_received {:gh, {:log, _}}
    end

    test "a re-run still running waits, however its old failed rows read" do
      recs = [CiRecovery.record(@head, :rerun, ["100"], @now)]

      assert {:wait, reason} = decide([check("test (8)", 100, 900)], recs, world(%{{:status, "100"} => {"queued\n", 0}}))
      assert reason =~ "re-run"
    end

    test "a merge of main that has not moved the head yet waits, and stops waiting after ten minutes" do
      recs = [CiRecovery.record(@head, :merge_main, ["100"], DateTime.add(@now, -60))]
      assert {:wait, _} = decide([check("test (8)", 100, 900)], recs, world())

      stale = [CiRecovery.record(@head, :merge_main, ["100"], DateTime.add(@now, -601))]
      assert {:recover, :rerun, _, _} = decide([check("test (8)", 100, 900)], stale, world())
    end
  end

  describe "a spent recovery goes to Fix CI" do
    test "a re-run that failed again on the same head goes to Fix CI" do
      recs = [CiRecovery.record(@head, :rerun, ["100"], @now)]

      assert {:fix_ci, reason} = decide([check("test (8)", 100, 900)], recs, world())
      assert reason =~ "the re-run on head `0c6cc513c1a5` failed again"
    end

    test "a re-run recorded on an older head does not count against this one" do
      recs = [CiRecovery.record("older", :rerun, ["99"], @now)]

      assert {:recover, :rerun, ["100"], _} = decide([check("test (8)", 100, 900)], recs, world())
    end

    test "the plan's recovery budget caps the chain, so merge and re-run cannot loop" do
      recs = for n <- 1..CiRecovery.max_recoveries(), do: CiRecovery.record("h#{n}", :rerun, ["#{n}"], @now)

      assert {:fix_ci, reason} = decide([check("test (8)", 100, 900)], recs, world())
      assert reason =~ "recoveries already ran on this plan"
    end
  end

  describe "main carries the fix" do
    defp main_moved(merge_base_conclusion) do
      world(%{
        :compare => {Jason.encode!(%{"ahead_by" => 4, "merge_base_commit" => %{"sha" => "base0"}}), 0},
        {:checks, "main"} => {check_runs([{2, "checks", "success"}, {1, "checks", "failure"}]), 0},
        {:checks, "base0"} => {check_runs([{1, "checks", merge_base_conclusion}]), 0},
        {:steps, "900"} => {steps("Mix Check"), 0},
        {:log, "900"} => {log_lines("checks", ["Found packages with security advisories: lazy_html"]), 0}
      })
    end

    test "a check red on the merge base and green on main's head merges main in (#4001)" do
      assert {:recover, :merge_main, ["100"], reason} = decide([check("checks", 100, 900)], [], main_moved("failure"))
      assert reason =~ "`main` is green on checks"
    end

    test "a check green on the merge base is a flake: re-run it, do not merge main for it" do
      assert {:recover, :rerun, ["100"], _} = decide([check("checks", 100, 900)], [], main_moved("success"))
    end

    test "after a spent re-run, a main that is green and ahead is merged in" do
      recs = [CiRecovery.record(@head, :rerun, ["100"], @now)]

      assert {:recover, :merge_main, _, _} = decide([check("checks", 100, 900)], recs, main_moved("success"))
    end

    test "main still red on the check is no fix" do
      w = Map.put(main_moved("failure"), {:checks, "main"}, {check_runs([{3, "checks", "failure"}]), 0})

      assert {:recover, :rerun, _, _} = decide([check("checks", 100, 900)], [], w)
    end

    test "the merge updates the branch by merge, never by rebase" do
      assert CiRecovery.act(@pr, :merge_main, ["100"], gh(%{:update_branch => {"", 0}})) == :ok
      assert_received {:gh, :update_branch}
    end
  end

  describe "failure_paths/1" do
    test "reads ExUnit failure blocks through gh's prefix and ANSI colour" do
      log = log_lines("test (2)", ["\e[31m  3) test lists the BU state (Gf.ListBuStateTest)\e[0m", "     test/gf/list_bu_state_per_load_test.exs:88"])

      assert CiRecovery.failure_paths(log) == ["test/gf/list_bu_state_per_load_test.exs"]
    end

    test "ignores the paths a passing run prints anyway: timing tables, shard lists, budgets" do
      log =
        log_lines("test (8)", [
          "Result: 4373 passed, 23 skipped, 2 excluded",
          "  * test infinite scroll (GfWeb.IssuesLiveTest) (9039.8ms) [test/gf_web/live/issues_live_test.exs:5044]",
          "  GF_CHANGED_TEST_FILES: test/gf_web/user_auth_test.exs",
          "[budget] ok   test/gf_web/user_auth_test.exs: 2.4s of shard time"
        ])

      assert CiRecovery.failure_paths(log) == []
    end

    test "reads Credo and mix format output" do
      log =
        log_lines("checks", [
          "┃       lib/gf/accounts.ex:40:3 #(Gf.Accounts.get/1)",
          "The following files are not formatted:",
          "  * lib/gf/outreach/first_request_copy.ex"
        ])

      assert CiRecovery.failure_paths(log) == ["lib/gf/accounts.ex", "lib/gf/outreach/first_request_copy.ex"]
    end
  end

  describe "classify_steps/1" do
    test "a first failed step that sets up is setup; one that runs the work is work" do
      assert CiRecovery.classify_steps(Jason.decode!(steps("Install PDF rasterizer"))) == {:setup, "Install PDF rasterizer"}
      assert CiRecovery.classify_steps(Jason.decode!(steps("Initialize containers"))) == {:setup, "Initialize containers"}
      assert CiRecovery.classify_steps(Jason.decode!(steps("Elixir Test"))) == {:work, "Elixir Test"}
      assert CiRecovery.classify_steps(%{"steps" => []}) == :none
    end
  end

  test "the orchestrator sends red CI through the recovery, and a wait dispatches nothing" do
    # Pinned against the source: ci_gate/3 needs gh and a plan store. Dropping either
    # line sends every red back to Fix CI (GEA-10757).
    src = File.read!(Path.expand("../../lib/symphony_elixir/orchestrator.ex", __DIR__))

    assert src =~ "CiRecovery.decide(pr, head, failing, recoveries, &gh_cmd/1)"
    assert src =~ "{:ci_wait, reason} ->\n"
    assert src =~ ~r/\{:wait, reason\} ->\n\s+# Something outside the worker is moving.*?complete_issue\(state, issue.id\)/s
  end
end
