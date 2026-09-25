defmodule SymphonyElixir.Planning.GraderCoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Dispatch, Grader}
  alias SymphonyElixir.Repo

  # A OneShot session that replays queued replies; `{:start_error, reason}`
  # makes the session fail to start.
  defmodule FakeSession do
    def start_session(_workspace, session_id, opts) do
      Process.put(:model, Keyword.get(opts, :model))

      case Process.get(:replies, []) do
        [{:start_error, reason} | rest] ->
          Process.put(:replies, rest)
          {:error, reason}

        _ ->
          {:ok, %{session_id: session_id}}
      end
    end

    def send_prompt(%{session_id: sid}, prompt, _turn) do
      Process.put(:prompt, prompt)
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

    defp jsonl_path(sid), do: Path.join(System.tmp_dir!(), "grader-cov-#{sid}.jsonl")
  end

  defmodule OkWatcher do
    def start_link(_opts), do: {:ok, :watcher}
    def wait_for_turn(:watcher, _timeout), do: {:ok, %{}}
    def stop(:watcher), do: :ok
  end

  setup_all do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-grader-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow_file = Path.join(root, "WORKFLOW.md")

    File.write!(workflow_file, """
    ---
    claude:
      model: opus
      grade_model: sonnet
    ---
    prompt
    """)

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(root)
    end)

    id = System.unique_integer([:positive])

    {:ok, plan} =
      Planning.upsert_plan(%{
        issue_id: "uuid-#{id}",
        issue_identifier: "GRD-#{id}",
        plan_json: %{
          "rows" => [
            %{"id" => "R1", "description" => "Filters", "state" => "missing"},
            %{"id" => "R2", "description" => "Sorting", "state" => "missing"}
          ]
        }
      })

    {:ok, dispatch} =
      Planning.record_dispatch(%{
        plan_id: plan.id,
        role: "implement",
        assigned_rows_json: %{"rows" => [%{"id" => "R1", "description" => "Filters"}]}
      })

    %{plan: plan, dispatch: dispatch}
  end

  defp migrations_path do
    Path.join([Application.app_dir(:symphony_elixir), "..", "..", "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end

  defp evidence(plan, replies, extra \\ []) do
    Process.put(:replies, replies)
    [plan: plan, session_module: FakeSession, watcher_module: OkWatcher, cwd: System.tmp_dir!()] ++ extra
  end

  defp grade_reply(verdict, rows), do: Jason.encode!(%{"verdict" => verdict, "rationale" => "why", "rows" => rows})

  test "persists an approving grade on the grade model and sends every evidence section", %{plan: plan, dispatch: dispatch} do
    reply = grade_reply("approve", [%{"id" => "R1", "state" => "done", "note" => "lib/x.ex"}])

    extra = [
      diff: "lib/filters.ex (+10/-0)",
      test_output: "10 tests, 0 failures",
      notes: "screenshots on Linear",
      pr_body: "## Status table",
      census: "Foo.bar/2 callers: lib/a.ex:3"
    ]

    assert {:ok, %Dispatch{} = graded} = Grader.grade(dispatch, evidence(plan, [reply], extra))

    assert graded.grade_json["verdict"] == "approve"
    assert graded.finished_at != nil
    assert Repo.get!(Dispatch, dispatch.id).grade_json["rows"] == [%{"id" => "R1", "state" => "done", "note" => "lib/x.ex"}]
    assert Process.get(:model) == "sonnet"

    prompt = Process.get(:prompt)
    assert prompt =~ "## Plan (full context)"
    assert prompt =~ "Sorting"
    assert prompt =~ "## Rows assigned to this dispatch"
    assert prompt =~ "lib/filters.ex (+10/-0)"
    assert prompt =~ "## Change census (callers the diff may have forgotten)"
    assert prompt =~ "Foo.bar/2 callers: lib/a.ex:3"
    assert prompt =~ "## PR description (live from GitHub)"
    assert prompt =~ "## Status table"
    assert prompt =~ "10 tests, 0 failures"
    assert prompt =~ "## Additional context\n\nscreenshots on Linear"
  end

  test "truncates an oversized diff and omits empty optional sections", %{plan: plan, dispatch: dispatch} do
    reply = grade_reply("request_changes", [%{"id" => "R1", "state" => "partial"}])
    extra = [diff: String.duplicate("x", 200_050), test_output: nil, pr_body: "", census: "(change census: no changes)"]

    assert {:ok, graded} = Grader.grade(dispatch, evidence(plan, [reply], extra))
    assert graded.grade_json["verdict"] == "request_changes"

    prompt = Process.get(:prompt)
    assert prompt =~ "[...truncated]"
    refute prompt =~ String.duplicate("x", 200_001)
    refute prompt =~ "## Change census"
    refute prompt =~ "## PR description"
    refute prompt =~ "## Additional context"
  end

  test "omits a census that is not a string", %{plan: plan, dispatch: dispatch} do
    reply = grade_reply("blocked", [%{"id" => "R1", "state" => "missing"}])

    assert {:ok, _} = Grader.grade(dispatch, evidence(plan, [reply], census: nil))
    refute Process.get(:prompt) =~ "## Change census"
  end

  test "rejects a grade that skips an assigned row", %{plan: plan, dispatch: dispatch} do
    reply = grade_reply("approve", [%{"id" => "R2", "state" => "done"}])

    log =
      capture_log(fn ->
        assert {:error, {:invalid_grade_shape, msg}} = Grader.grade(dispatch, evidence(plan, [reply]))
        assert msg =~ ~s(missing grades for rows: ["R1"])
      end)

    assert log =~ "Grader failed for dispatch=#{dispatch.id}"
    assert Repo.get!(Dispatch, dispatch.id).grade_json == nil
  end

  test "rejects malformed rows instead of crashing", %{plan: plan, dispatch: dispatch} do
    reply = Jason.encode!(%{"verdict" => "approve", "rows" => ["R1"]})

    capture_log(fn ->
      assert {:error, {:invalid_grade_shape, "rows missing required fields"}} =
               Grader.grade(dispatch, evidence(plan, [reply]))
    end)
  end

  test "rejects an unknown verdict", %{plan: plan, dispatch: dispatch} do
    reply = grade_reply("ship_it", [%{"id" => "R1", "state" => "done"}])

    capture_log(fn ->
      assert {:error, {:invalid_grade_shape, "bad top-level keys"}} =
               Grader.grade(dispatch, evidence(plan, [reply]))
    end)
  end

  test "a dispatch without assigned rows accepts any well-formed grade", %{plan: plan, dispatch: dispatch} do
    dispatch = %{dispatch | assigned_rows_json: nil}
    reply = grade_reply("approve", [])

    assert {:ok, graded} = Grader.grade(dispatch, evidence(plan, [reply]))
    assert graded.grade_json["rows"] == []
  end

  test "surfaces a model session failure", %{plan: plan, dispatch: dispatch} do
    capture_log(fn ->
      assert {:error, {:start_session_failed, :down}} =
               Grader.grade(dispatch, evidence(%{plan | plan_json: nil}, [{:start_error, :down}]))
    end)
  end
end
