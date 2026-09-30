defmodule SymphonyElixir.Claude.AgentRunnerTest do
  @moduledoc """
  Drives the refactored turn loop with fake `session_module` / `watcher_module`
  collaborators, so the orchestration (turn sequencing, stop conditions, error
  propagation) is tested without a live tmux/Claude session.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AgentRunner
  alias SymphonyElixir.Linear.Issue

  # --- Fake collaborators ----------------------------------------------------

  defmodule FakeSession do
    @moduledoc false
    def start_session(_workspace, session_id, _opts), do: {:ok, %{session_id: session_id}}

    def send_prompt(_session, _prompt, turn) do
      relay({:sent_prompt, turn})
      Process.get(:fake_send_result, :ok)
    end

    def await_jsonl(_session_id), do: {:ok, "/tmp/fake.jsonl"}
    def stop_session(_session), do: relay(:stopped)

    defp relay(msg) do
      case Application.get_env(:symphony_elixir, :agent_runner_test_pid) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule FakeWatcher do
    @moduledoc false
    def start_link(_opts), do: {:ok, spawn(fn -> :ok end)}

    def wait_for_turn(_watcher, _timeout) do
      # A test can make the "agent" do work in the turn, e.g. commit in the slot.
      case Application.get_env(:symphony_elixir, :fake_turn_work) do
        work when is_function(work, 0) -> work.()
        _ -> :ok
      end

      case Application.get_env(:symphony_elixir, :fake_wait_result, :ok) do
        :timeout ->
          {:error, :timeout}

        :ok ->
          {:ok,
           %{
             turn: 0,
             stop_reason: "end_turn",
             usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
           }}
      end
    end

    def stop(_watcher), do: :ok
  end

  # --- Helpers ---------------------------------------------------------------

  defp issue(state) do
    %Issue{id: "issue-1", identifier: "TST-1", title: "Test issue", description: "x", state: state}
  end

  defp base_opts(extra) do
    Keyword.merge(
      [
        session_module: FakeSession,
        watcher_module: FakeWatcher,
        comment_fetcher: fn _id, _after -> {:ok, []} end
      ],
      extra
    )
  end

  setup do
    Application.put_env(:symphony_elixir, :agent_runner_test_pid, self())
    Application.delete_env(:symphony_elixir, :fake_wait_result)
    Application.delete_env(:symphony_elixir, :fake_turn_work)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :fake_turn_work)
      Application.delete_env(:symphony_elixir, :agent_runner_test_pid)
      Application.delete_env(:symphony_elixir, :fake_wait_result)
      File.rm_rf(Path.join(SymphonyElixir.Config.workspace_root(), "TST-1"))
    end)

    :ok
  end

  defp sent_turns do
    Stream.repeatedly(fn ->
      receive do
        {:sent_prompt, turn} -> turn
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  # --- Tests -----------------------------------------------------------------

  test "stops after max_turns while the issue stays active" do
    opts =
      base_opts(
        max_turns: 3,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    assert sent_turns() == [1, 2, 3]
    assert_received :stopped
  end

  # The fake workspace is not a git tree, so every turn reads as no progress:
  # turns 1-3 are free, and turns 4, 5 and 6 fill the watchdog.
  test "a worker run with no file changes stops after turn 6" do
    opts =
      base_opts(
        max_turns: 10,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    assert sent_turns() == [1, 2, 3, 4, 5, 6]
  end

  # GEA-10754: the progress check ran git in the scratch workspace, which only
  # holds `.symphony_slot`, so a worker that committed every turn still read as
  # no progress and was stopped at turn 6. It must read the slot the marker
  # names. The slot branch has no upstream, as a freshly provisioned one has not.
  @tag :tmp_dir
  test "a commit in the slot each turn counts as progress", %{tmp_dir: tmp_dir} do
    slot = Path.join(tmp_dir, "slot")
    File.mkdir_p!(slot)
    git = fn args -> {_, 0} = System.cmd("git", args, cd: slot, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "gea-1-work"])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"])

    workspace = Path.join(SymphonyElixir.Config.workspace_root(), "TST-1")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, ".symphony_slot"), "SLOT_NAME=slot\nDIRECTORY=#{slot}\n")

    Application.put_env(:symphony_elixir, :fake_turn_work, fn ->
      git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "turn"])
    end)

    opts =
      base_opts(
        max_turns: 10,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    assert sent_turns() == Enum.to_list(1..10)
  end

  # GEA-10667: the tester is read-only, so no file changes is its normal state.
  # Stopped at turn 6, it never wrote its SYMPHONY_VERDICT line.
  test "a Test run is not stopped for making no file changes" do
    opts =
      base_opts(
        max_turns: 10,
        retask_phases: ["Test"],
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    assert sent_turns() == Enum.to_list(1..10)
  end

  test "stops once the issue reaches a terminal state" do
    opts =
      base_opts(
        max_turns: 10,
        issue_state_fetcher: fn _ids -> {:ok, [issue("Done")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), nil, opts)
    # Only the first prompt is sent; after turn 1 the issue is terminal.
    assert sent_turns() == [1]
    assert_received :stopped
  end

  test "raises and still stops the session when a turn times out" do
    Application.put_env(:symphony_elixir, :fake_wait_result, :timeout)

    opts =
      base_opts(
        max_turns: 3,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert_raise RuntimeError, fn -> AgentRunner.run(issue("In Progress"), nil, opts) end
    assert sent_turns() == [1]
    assert_received :stopped
  end

  test "emits a :turn_completed update carrying the turn number for the TURN counter" do
    opts =
      base_opts(
        max_turns: 3,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert :ok = AgentRunner.run(issue("In Progress"), self(), opts)

    turns =
      Stream.repeatedly(fn ->
        receive do
          {:codex_worker_update, _id, %{event: :turn_completed} = u} -> {u.turn, u.usage}
          {:codex_worker_update, _id, _other} -> :skip
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.reject(&(&1 == :skip))

    # One :turn_completed per turn carrying the turn number; token usage rides on
    # the per-event updates instead (so the dashboard climbs live mid-turn).
    assert turns == [{1, nil}, {2, nil}, {3, nil}]
  end

  test "raises and stops the session when start_session fails" do
    defmodule FailingSession do
      def start_session(_w, _s, _o), do: {:error, :no_tmux}
      def send_prompt(_s, _p, _t), do: :ok
      def await_jsonl(_s), do: {:ok, "/tmp/x.jsonl"}
      def stop_session(_s), do: :ok
    end

    opts =
      base_opts(
        session_module: FailingSession,
        issue_state_fetcher: fn _ids -> {:ok, [issue("In Progress")]} end
      )

    assert_raise RuntimeError, fn -> AgentRunner.run(issue("In Progress"), nil, opts) end
  end
end
