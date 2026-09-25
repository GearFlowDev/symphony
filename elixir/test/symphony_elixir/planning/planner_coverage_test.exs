defmodule SymphonyElixir.Planning.PlannerCoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Plan, Planner}
  alias SymphonyElixir.Repo

  # A OneShot session that replays queued replies. Each queue entry is either a
  # reply text (written to the session JSONL) or `{:start_error, reason}`.
  defmodule FakeSession do
    def start_session(_workspace, session_id, opts) do
      Process.put(:models_tried, Process.get(:models_tried, []) ++ [Keyword.get(opts, :model)])

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

    defp jsonl_path(sid), do: Path.join(System.tmp_dir!(), "planner-cov-#{sid}.jsonl")
  end

  defmodule OkWatcher do
    def start_link(_opts), do: {:ok, :watcher}
    def wait_for_turn(:watcher, _timeout), do: {:ok, %{}}
    def stop(:watcher), do: :ok
  end

  defmodule MemoryLinearClient do
    def graphql(_query, _variables) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "plan-comment"}}}}}
    end
  end

  setup_all do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "symphony-planner-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow_file = Path.join(root, "WORKFLOW.md")
    plan_model_line = Map.get(context, :plan_model_line, "  plan_model: fable\n")

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
    claude:
      model: opus
    #{plan_model_line}---
    prompt
    """)

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, MemoryLinearClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end

      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(root)
    end)

    :ok
  end

  defp migrations_path do
    Path.join([Application.app_dir(:symphony_elixir), "..", "..", "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end

  defp opts(replies, extra \\ []) do
    Process.put(:replies, replies)
    Process.put(:prompts, [])
    Process.put(:models_tried, [])
    [session_module: FakeSession, watcher_module: OkWatcher, cwd: System.tmp_dir!()] ++ extra
  end

  defp issue do
    id = System.unique_integer([:positive])
    %{id: "uuid-#{id}", identifier: "PLN-#{id}", title: "Add filters", description: "Body text", labels: ["ui", "p1"]}
  end

  @good_plan ~s({"rows": [{"id": "R1", "description": "Filters", "state": "missing"}], "notes": "n"})

  test "persists the model's plan, mirrors it to Linear, and sends every context section" do
    issue = issue()

    prior = %Plan{plan_json: %{"rows" => [%{"id" => "OLD-1", "description" => "old", "state" => "done"}]}}

    extra = [
      process_docs: [{"docs/process.md", "follow the process"}],
      audit_summary: "3 files changed",
      prior_plan: prior,
      metadata: %{"source" => "test"}
    ]

    assert {:ok, %Plan{} = plan} = Planner.plan(issue, opts([@good_plan], extra))

    assert plan.status == "dispatching"
    assert plan.issue_identifier == issue.identifier
    assert [%{"id" => "R1", "state" => "missing"}] = Plan.rows(plan)
    assert plan.metadata["source"] == "test"
    assert {:ok, _, _} = DateTime.from_iso8601(plan.metadata["generated_at"])
    assert plan.linear_comment_id == "plan-comment"
    assert Planning.get_plan_by_issue(issue.identifier).id == plan.id

    assert Process.get(:models_tried) == ["fable"]
    [prompt] = Process.get(:prompts)
    assert prompt =~ "- ID: #{issue.identifier}"
    assert prompt =~ "- Title: Add filters"
    assert prompt =~ "- Labels: ui, p1"
    assert prompt =~ "Body text"
    assert prompt =~ "## Process docs\n\n### docs/process.md\n\nfollow the process"
    assert prompt =~ "## WIP branch audit summary\n\n3 files changed"
    assert prompt =~ "## Prior plan rows (preserve IDs where possible)"
    assert prompt =~ "OLD-1"
  end

  test "accepts a string-keyed issue and omits empty optional sections" do
    id = System.unique_integer([:positive])
    issue = %{"id" => "uuid-#{id}", "identifier" => "PLN-#{id}", "title" => "T"}

    assert {:ok, plan} =
             Planner.plan(issue, opts([@good_plan], audit_summary: "", prior_plan: %Plan{plan_json: %{}}, metadata: nil))

    assert plan.issue_id == "uuid-#{id}"
    assert Map.keys(plan.metadata) == ["generated_at"]

    [prompt] = Process.get(:prompts)
    assert prompt =~ "- Labels: \n"
    refute prompt =~ "## WIP branch audit summary"
    refute prompt =~ "## Prior plan rows"
    refute prompt =~ "## Process docs"
  end

  test "retries on the default model when the plan model cannot start" do
    assert {:ok, %Plan{}} =
             capture_log_result(fn -> Planner.plan(issue(), opts([{:start_error, :no_fable}, @good_plan])) end)

    assert Process.get(:models_tried) == ["fable", "opus"]
  end

  @tag plan_model_line: ""
  test "does not retry when the plan model is already the default model" do
    log =
      capture_log(fn ->
        assert {:error, {:start_session_failed, :down}} =
                 Planner.plan(issue(), opts([{:start_error, :down}]))
      end)

    assert Process.get(:models_tried) == ["opus"]
    assert log =~ "Planner failed for issue=PLN-"
  end

  test "rejects a plan whose rows lack required fields" do
    log =
      capture_log(fn ->
        assert {:error, {:invalid_plan_shape, "rows missing required fields"}} =
                 Planner.plan(issue(), opts([~s({"rows": [{"id": "R1", "state": "bogus"}]})]))
      end)

    assert log =~ "invalid_plan_shape"
  end

  test "rejects a reply without a rows array" do
    capture_log(fn ->
      assert {:error, {:invalid_plan_shape, "missing rows array"}} =
               Planner.plan(issue(), opts([~s({"plan": []})]))
    end)
  end

  test "surfaces a persistence failure and logs an unknown issue" do
    log =
      capture_log(fn ->
        assert {:error, %Ecto.Changeset{}} = Planner.plan(%{title: "no ids"}, opts([@good_plan]))
      end)

    assert log =~ "Planner failed for issue=unknown"
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
