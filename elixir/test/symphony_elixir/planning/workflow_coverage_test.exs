defmodule SymphonyElixir.Planning.WorkflowCoverageTest do
  # Sets the workflow file, the Linear client and PATH, so it runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Dispatch, Plan, Workflow}
  alias SymphonyElixir.Repo

  # A OneShot session that replays queued replies; `{:start_error, reason}`
  # makes the session fail to start.
  defmodule FakeSession do
    def start_session(_workspace, session_id, _opts) do
      case Process.get(:replies, []) do
        [{:start_error, reason} | rest] ->
          Process.put(:replies, rest)
          {:error, reason}

        _ ->
          {:ok, %{session_id: session_id}}
      end
    end

    def send_prompt(%{session_id: sid}, prompt, _turn) do
      Process.put(:prompts, Process.get(:prompts, []) ++ [prompt])
      [reply | rest] = Process.get(:replies)
      Process.put(:replies, rest)

      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => reply}], "stop_reason" => "end_turn"}
        })

      File.write!(jsonl_path(sid), line)
      :ok
    end

    def await_jsonl(session_id), do: {:ok, jsonl_path(session_id)}
    def stop_session(%{session_id: sid}), do: File.rm(jsonl_path(sid))

    defp jsonl_path(sid), do: Path.join(System.tmp_dir!(), "workflow-cov-#{sid}.jsonl")
  end

  defmodule OkWatcher do
    def start_link(_opts), do: {:ok, :watcher}
    def wait_for_turn(:watcher, _timeout), do: {:ok, %{}}
    def stop(:watcher), do: :ok
  end

  defmodule FakeLinearClient do
    def graphql(query, _variables) do
      if query =~ "commentUpdate" do
        {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
      else
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "wf-comment"}}}}}
      end
    end
  end

  setup_all do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-workflow-cov-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    workflow_file = Path.join(root, "WORKFLOW.md")

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
    claude:
      model: opus
    ---
    prompt
    """)

    # A fake gh: the PR search finds one PR, whose files and commits are fixed.
    gh = Path.join(bin, "gh")

    File.write!(gh, """
    #!/bin/sh
    case "$1 $2" in
      "search prs") echo '[{"url": "https://github.com/acme/widgets/pull/7"}]' ;;
      *) case "$2" in
           */files) echo '[{"path": "lib/filters.ex", "additions": 3, "deletions": 0, "status": "added"}]' ;;
           */commits) echo '[{"sha": "cafe0001", "msg": "R1 filters"}]' ;;
         esac ;;
    esac
    """)

    File.chmod!(gh, 0o755)
    old_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> old_path)

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end

      System.put_env("PATH", old_path)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(root)
    end)

    :ok
  end

  defp migrations_path do
    Path.join([Application.app_dir(:symphony_elixir), "..", "..", "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end

  defp fake_opts(replies) do
    Process.put(:replies, replies)
    Process.put(:prompts, [])
    [session_module: FakeSession, watcher_module: OkWatcher, cwd: System.tmp_dir!()]
  end

  defp issue do
    id = System.unique_integer([:positive])
    %{id: "uuid-#{id}", identifier: "WF-#{id}", title: "Filters", description: "Add filters"}
  end

  defp insert_plan(rows) do
    issue = issue()
    {:ok, plan} = Planning.upsert_plan(%{issue_id: issue.id, issue_identifier: issue.identifier, plan_json: %{"rows" => rows}})
    plan
  end

  @plan_reply ~s({"rows": [{"id": "R1", "description": "Filters", "state": "partial", "rationale": "started"}]})

  describe "assess/2" do
    test "plans a fresh issue from the audit of its open PR" do
      issue = issue()

      assert {:ok, {:has_open_rows, %Plan{} = plan, [%{"id" => "R1"}]}} =
               Workflow.assess(issue, fake_opts([@plan_reply]))

      assert plan.issue_identifier == issue.identifier
      [prompt] = Process.get(:prompts)
      assert prompt =~ "## WIP branch audit summary"
      assert prompt =~ "acme/widgets#PR#7"
      assert prompt =~ "cafe0001 R1 filters"
    end

    test "plans from the issue body alone when the audit fails" do
      opts = Keyword.put(fake_opts([@plan_reply]), :pr_url, "https://example.com/not-a-pr")

      log =
        capture_log(fn ->
          assert {:ok, {:has_open_rows, _plan, [_row]}} = Workflow.assess(issue(), opts)
        end)

      assert log =~ "Auditor failed for WF-"
      assert log =~ "planning from issue body only"
      refute hd(Process.get(:prompts)) =~ "## WIP branch audit summary"
    end

    test "returns the planner's error" do
      capture_log(fn ->
        assert {:error, {:start_session_failed, :down}} =
                 Workflow.assess(issue(), fake_opts([{:start_error, :down}, {:start_error, :down}]))
      end)
    end

    test "reuses an existing plan without calling the model" do
      plan = insert_plan([%{"id" => "R1", "description" => "d", "state" => "missing"}])

      assert {:ok, {:has_open_rows, %Plan{id: id}, [%{"id" => "R1"}]}} =
               Workflow.assess(%{"identifier" => plan.issue_identifier}, fake_opts([]))

      assert id == plan.id
      assert Process.get(:prompts) == []
    end

    test "reports a plan whose rows are all closed as complete" do
      plan =
        insert_plan([
          %{"id" => "R1", "description" => "d", "state" => "done"},
          %{"id" => "R2", "description" => "d", "state" => "deferred"}
        ])

      assert {:ok, {:complete, %Plan{}}} = Workflow.assess(%{identifier: plan.issue_identifier})
    end
  end

  describe "start_implement_dispatch/3" do
    test "records an implement dispatch with the assigned rows and slot" do
      plan = insert_plan([%{"id" => "R1", "description" => "d", "state" => "missing"}])
      rows = [%{"id" => "R1", "description" => "d"}]

      assert {:ok, %Dispatch{} = dispatch} = Workflow.start_implement_dispatch(plan, rows, slot_name: "slot-3")
      assert dispatch.role == "implement"
      assert dispatch.slot_name == "slot-3"
      assert dispatch.assigned_rows_json == %{"rows" => rows}
      assert dispatch.started_at != nil
    end
  end

  describe "grade_dispatch/2" do
    setup do
      plan =
        insert_plan([
          %{"id" => "R1", "description" => "Filters", "state" => "missing"},
          %{"id" => "R2", "description" => "Sorting", "state" => "missing", "rationale" => "kept"},
          %{"id" => "R3", "description" => "Export", "state" => "partial", "rationale" => "old note"}
        ])

      {:ok, dispatch} =
        Workflow.start_implement_dispatch(plan, [%{"id" => "R1"}, %{"id" => "R3"}])

      %{plan: plan, dispatch: dispatch}
    end

    defp grade(verdict, rows), do: Jason.encode!(%{"verdict" => verdict, "rationale" => "r", "rows" => rows})

    test "merges an approving grade into the plan and mirrors it", %{plan: plan, dispatch: dispatch} do
      reply = grade("approve", [%{"id" => "R1", "state" => "done", "note" => "lib/f.ex"}, %{"id" => "R3", "state" => "done"}])
      evidence = [plan: plan] ++ fake_opts([reply])

      assert {:ok, {:approve, updated}} = Workflow.grade_dispatch(dispatch, evidence)

      assert [r1, r2, r3] = Plan.rows(updated)
      assert r1 == %{"id" => "R1", "description" => "Filters", "state" => "done", "rationale" => "lib/f.ex"}
      # A row the grade does not name is left alone.
      assert r2 == %{"id" => "R2", "description" => "Sorting", "state" => "missing", "rationale" => "kept"}
      # A grade without a note keeps the old rationale.
      assert r3["state"] == "done"
      assert r3["rationale"] == "old note"
      assert updated.linear_comment_id == "wf-comment"
      assert Plan.rows(Planning.get_plan_by_issue(plan.issue_identifier)) == [r1, r2, r3]
    end

    test "maps request_changes and blocked verdicts to atoms", %{plan: plan, dispatch: dispatch} do
      rows = [%{"id" => "R1", "state" => "partial"}, %{"id" => "R3", "state" => "missing"}]

      assert {:ok, {:request_changes, updated}} =
               Workflow.grade_dispatch(dispatch, [plan: plan] ++ fake_opts([grade("request_changes", rows)]))

      assert Enum.map(Plan.rows(updated), & &1["state"]) == ["partial", "missing", "missing"]

      assert {:ok, {:blocked, _}} =
               Workflow.grade_dispatch(dispatch, [plan: updated] ++ fake_opts([grade("blocked", rows)]))
    end

    test "returns the grader's error untouched", %{plan: plan, dispatch: dispatch} do
      capture_log(fn ->
        assert {:error, {:invalid_grade_shape, "bad top-level keys"}} =
                 Workflow.grade_dispatch(dispatch, [plan: plan] ++ fake_opts([~s({"verdict": "maybe"})]))
      end)

      assert Planning.get_plan_by_issue(plan.issue_identifier).plan_json == plan.plan_json
    end
  end

  describe "plan_complete?/1 and mark_plan_done/1" do
    test "a plan is complete only when every row is done or deferred" do
      assert Workflow.plan_complete?(%Plan{plan_json: %{"rows" => [%{"state" => "done"}, %{"state" => "deferred"}]}})
      refute Workflow.plan_complete?(%Plan{plan_json: %{"rows" => [%{"state" => "done"}, %{"state" => "partial"}]}})
      assert Workflow.plan_complete?(%Plan{plan_json: %{}})
    end

    test "mark_plan_done/1 sets the plan status to done" do
      plan = insert_plan([])
      assert {:ok, %Plan{status: "done"}} = Workflow.mark_plan_done(plan)
      assert Planning.get_plan_by_issue(plan.issue_identifier).status == "done"
    end
  end
end
