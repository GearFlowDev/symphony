defmodule SymphonyElixir.Claude.AgentRunnerCoverageTest do
  @moduledoc """
  Drives `Claude.AgentRunner` through its remaining branches with fake session
  and watcher modules. `run/3` is synchronous, so every fake runs in the test
  process and reads its script from the process dictionary.
  """
  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  alias SymphonyElixir.Claude.{AgentRunner, StreamParser}

  defmodule ScriptedSession do
    @moduledoc false
    def start_session(_workspace, session_id, _opts) do
      send(self(), {:session_id, session_id})
      {:ok, :session}
    end

    def send_prompt(:session, prompt, turn) do
      send(self(), {:sent_prompt, turn, prompt})

      case Process.get(:fail_send_on_turn) do
        ^turn -> {:error, :pane_gone}
        _ -> :ok
      end
    end

    def await_jsonl(_session_id), do: Process.get(:await_jsonl_result, {:ok, "/tmp/fake.jsonl"})
    def stop_session(:session), do: send(self(), :session_stopped)
  end

  defmodule ScriptedWatcher do
    @moduledoc false
    def start_link(opts) do
      Process.put(:on_event, Keyword.fetch!(opts, :on_event))
      {:ok, :watcher}
    end

    def wait_for_turn(:watcher, _timeout) do
      on_event = Process.get(:on_event)
      Enum.each(Process.get(:events_per_turn, []), on_event)
      {:ok, %{}}
    end

    def stop(:watcher), do: send(self(), :watcher_stopped)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-ar-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp issue(state, id \\ "issue-1") do
    %Issue{id: id, identifier: "COV-1", title: "Cov", description: "x", state: state}
  end

  defp opts(extra) do
    Keyword.merge(
      [
        session_module: ScriptedSession,
        watcher_module: ScriptedWatcher,
        comment_fetcher: fn _id, _after -> {:ok, []} end,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      ],
      extra
    )
  end

  defp sent_prompts do
    Stream.repeatedly(fn ->
      receive do
        {:sent_prompt, turn, prompt} -> {turn, prompt}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  test "generates a v4 UUID session id and relays parsed events to the recipient" do
    line = ~s({"type":"assistant","sessionId":"sess-9","message":{"usage":{"output_tokens":4}}})
    {:ok, event} = StreamParser.parse_line(line)
    Process.put(:events_per_turn, [event])

    assert :ok = AgentRunner.run(issue("In Progress"), self(), opts(max_turns: 1))

    assert_received {:session_id, session_id}
    assert session_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert_received {:codex_worker_update, "issue-1", %{event: :claude_starting}}

    assert_received {:codex_worker_update, "issue-1", %{event: :assistant, session_id: "sess-9", usage: usage, raw: ^event}}
    assert usage == %{input_tokens: 0, output_tokens: 4, total_tokens: 4}

    assert_received {:codex_worker_update, "issue-1", %{event: :turn_completed, turn: 1}}
    assert_received :watcher_stopped
    assert_received :session_stopped
  end

  test "an issue without a binary id gets no updates and stops after the first turn" do
    Process.put(:events_per_turn, [%{event_type: :assistant}])
    no_id = %Issue{id: nil, identifier: "COV-1", title: "Cov", state: "In Progress"}

    assert :ok = AgentRunner.run(no_id, self(), opts(max_turns: 5))
    assert [{1, _}] = sent_prompts()
    refute_received {:codex_worker_update, nil, %{event: :assistant}}
    refute_received {:codex_worker_update, nil, %{event: :turn_completed}}
  end

  test "stops early after three consecutive turns without workspace progress" do
    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 20))
    assert Enum.map(sent_prompts(), &elem(&1, 0)) == [1, 2, 3, 4, 5, 6]
  end

  test "an empty issue-state refresh ends the run" do
    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 5, issue_state_fetcher: fn _ -> {:ok, []} end))
    assert [{1, _}] = sent_prompts()
  end

  test "retries a failed issue-state refresh and continues on success" do
    counter = :counters.new(1, [])

    fetcher = fn ids ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        {:error, :closed}
      else
        assert ids == ["issue-1"]
        {:ok, [issue("In Progress")]}
      end
    end

    log =
      capture_log(fn ->
        assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 2, issue_state_fetcher: fetcher))
      end)

    assert log =~ "retrying in 2000ms"
    assert Enum.map(sent_prompts(), &elem(&1, 0)) == [1, 2]
  end

  test "turn 2+ prompts include new comments from the comment fetcher" do
    fetcher = fn "issue-1", %DateTime{} ->
      {:ok, [%{author: "Reviewer", body: "use the helper", created_at: ~U[2026-09-25 10:00:00Z]}]}
    end

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 2, comment_fetcher: fetcher))
    [{1, first}, {2, second}] = sent_prompts()
    refute first =~ "use the helper"
    assert second =~ "Continuation guidance (turn 2/2)"
    assert second =~ "[10:00 UTC] Reviewer: use the helper"
  end

  test "a failing comment fetch yields a continuation without comments" do
    assert :ok =
             AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 2, comment_fetcher: fn _, _ -> {:error, :boom} end))

    [{1, _}, {2, second}] = sent_prompts()
    refute second =~ "New comments on the Linear issue"
  end

  test "a single retask phase drives phase prompts and phase continuations" do
    assert :ok =
             AgentRunner.run(
               issue("In Progress"),
               nil,
               opts(max_turns: 2, retask_phases: ["Test"], assigned_rows: [%{"id" => "row-a", "state" => "partial"}])
             )

    [{1, first}, {2, second}] = sent_prompts()
    assert first =~ "Complete the Test phase."
    assert second =~ "**Test phase only**"
    assert second =~ "**row-a** (partial)"
  end

  test "several retask phases use the retask prompt" do
    assert :ok =
             AgentRunner.run(
               issue("In Progress"),
               nil,
               opts(max_turns: 1, retask_phases: ["Test", "Ship"], completed_phases: ["Implement"])
             )

    [{1, first}] = sent_prompts()
    assert first =~ "You are continuing work on COV-1."
    assert first =~ "- Implement"
    assert first =~ "### Ship (INCOMPLETE)"
  end

  test "a failed prompt send on a later turn fails the run and stops the session" do
    Process.put(:fail_send_on_turn, 2)

    assert_raise RuntimeError, ~r/send_prompt_failed.*pane_gone/, fn ->
      capture_log(fn -> AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 3)) end)
    end

    assert_received :watcher_stopped
    assert_received :session_stopped
  end

  test "a missing JSONL fails the run without starting a watcher" do
    Process.put(:await_jsonl_result, {:error, :jsonl_not_found})

    assert_raise RuntimeError, ~r/jsonl_not_found/, fn ->
      capture_log(fn -> AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 3)) end)
    end

    refute_received :watcher_stopped
    assert_received :session_stopped
  end

  test "a before_run hook with no capacity exits with :no_capacity", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_run: "exit 75")

    assert catch_exit(capture_log(fn -> AgentRunner.run(issue("In Progress"), nil, opts([])) end)) ==
             {:shutdown, :no_capacity}

    refute_received {:sent_prompt, _, _}
  end

  test "workspace creation failure raises", %{root: root} do
    blocker = Path.join(root, "not-a-dir")
    File.write!(blocker, "x")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(blocker, "nested"))

    assert_raise RuntimeError, ~r/Claude agent run failed for issue_id=issue-1/, fn ->
      capture_log(fn -> AgentRunner.run(issue("In Progress"), nil, opts([])) end)
    end
  end

  test "run/1 uses the default recipient and opts (stopped here by a full pool)", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_run: "exit 75")
    assert catch_exit(AgentRunner.run(issue("In Progress"))) == {:shutdown, :no_capacity}
  end

  test "a refreshed issue without a state is treated as done" do
    fetcher = fn _ -> {:ok, [%Issue{id: "issue-1", identifier: "COV-1", state: nil}]} end
    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 5, issue_state_fetcher: fetcher))
    assert [{1, _}] = sent_prompts()
  end

  test "git changes and unpushed commits count as progress and keep the run going", %{root: root} do
    workspace = Path.join(root, "COV-1")
    File.mkdir_p!(workspace)
    git = fn args -> {_, 0} = System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: workspace) end
    git.(["init", "-q", "-b", "main"])
    File.write!(Path.join(workspace, "a.txt"), "one\n")
    git.(["add", "a.txt"])
    git.(["commit", "-q", "-m", "base"])
    git.(["branch", "base"])
    git.(["branch", "--set-upstream-to=base"])
    git.(["commit", "-q", "--allow-empty", "-m", "unpushed"])
    File.write!(Path.join(workspace, "a.txt"), "two\n")

    log = capture_log(fn -> assert :ok = AgentRunner.run(issue("In Progress"), nil, opts(max_turns: 8)) end)

    assert Enum.map(sent_prompts(), &elem(&1, 0)) == Enum.to_list(1..8)
    assert log =~ "progress=%{files_changed: 2, new_commits: 1}"
    refute log =~ "stopping early"
  end
end
