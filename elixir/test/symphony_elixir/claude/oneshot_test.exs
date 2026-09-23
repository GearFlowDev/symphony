defmodule SymphonyElixir.Claude.OneShotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.OneShot

  # The watcher just signals that the single turn completed. OneShot reads the
  # reply from the JSONL the fake session writes, not from the watcher.
  defmodule OkWatcher do
    def start_link(_opts), do: {:ok, :fake_watcher}
    def wait_for_turn(:fake_watcher, _timeout), do: {:ok, %{turn: 1, stop_reason: "end_turn", usage: nil}}
    def stop(:fake_watcher), do: :ok
  end

  defmodule TimeoutWatcher do
    def start_link(_opts), do: {:ok, :fake_watcher}
    def wait_for_turn(:fake_watcher, _timeout), do: {:error, :timeout}
    def stop(:fake_watcher), do: :ok
  end

  # Runs in the same process as the test, so it records call args via the process
  # dictionary and pops one queued JSONL fixture per prompt sent.
  defmodule FakeSession do
    def start_session(workspace, session_id, opts) do
      Process.put(:start_args, {workspace, session_id, opts})
      {:ok, %{session_id: session_id, workspace: workspace}}
    end

    def send_prompt(%{session_id: sid}, prompt, turn) do
      Process.put(:last_prompt, {prompt, turn})
      [fixture | rest] = Process.get(:fixtures)
      Process.put(:fixtures, rest)
      File.write!(jsonl_path(sid), fixture)
      :ok
    end

    def await_jsonl(session_id), do: {:ok, jsonl_path(session_id)}

    def stop_session(_session) do
      Process.put(:stopped?, true)
      :ok
    end

    def jsonl_path(sid), do: Path.join(System.tmp_dir!(), "oneshot-test-#{sid}.jsonl")
  end

  defp assistant_line(text, opts \\ []) do
    sidechain = Keyword.get(opts, :sidechain, false)

    %{
      "type" => "assistant",
      "isSidechain" => sidechain,
      "message" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => "end_turn"
      }
    }
    |> Jason.encode!()
  end

  defp fakes(fixtures) do
    Process.put(:fixtures, List.wrap(fixtures))

    [
      session_module: FakeSession,
      watcher_module: OkWatcher,
      cwd: System.tmp_dir!()
    ]
  end

  test "request returns the assistant text and tears the session down" do
    fixture = assistant_line("the answer is 42")

    assert {:ok, "the answer is 42"} =
             OneShot.request("you are a judge", "what is the answer?", fakes(fixture))

    assert Process.get(:stopped?) == true
  end

  test "request starts a no-tools session with the system prompt appended" do
    OneShot.request("SYSTEM PROMPT", "hi", fakes(assistant_line("ok")))

    {_workspace, _session_id, start_opts} = Process.get(:start_args)
    assert Keyword.get(start_opts, :tools) == ""
    assert Keyword.get(start_opts, :append_system_prompt) == "SYSTEM PROMPT"

    assert {"hi", 1} = Process.get(:last_prompt)
  end

  test "request skips sidechain assistant messages and uses the main-chain reply" do
    fixture =
      [
        assistant_line("subagent chatter", sidechain: true),
        assistant_line("real answer")
      ]
      |> Enum.join("\n")

    assert {:ok, "real answer"} = OneShot.request("sys", "q", fakes(fixture))
  end

  test "request returns :empty_reply when the turn produced no assistant text" do
    empty = %{"type" => "assistant", "message" => %{"content" => []}} |> Jason.encode!()

    assert {:error, :empty_reply} = OneShot.request("sys", "q", fakes(empty))
  end

  test "request surfaces a turn timeout" do
    opts =
      fakes(assistant_line("never read"))
      |> Keyword.put(:watcher_module, TimeoutWatcher)

    assert {:error, {:turn_failed, :timeout}} = OneShot.request("sys", "q", opts)
  end

  test "request_json decodes a fenced JSON reply" do
    fixture = assistant_line(~s(```json\n{"verdict": "approve"}\n```))

    assert {:ok, %{"verdict" => "approve"}} =
             OneShot.request_json("sys", "grade this", fakes(fixture))
  end

  test "request_json retries once when the first reply is not JSON" do
    fixtures = [
      assistant_line("sorry, here is the grade:"),
      assistant_line(~s({"verdict": "request_changes"}))
    ]

    assert {:ok, %{"verdict" => "request_changes"}} =
             OneShot.request_json("sys", "grade this", fakes(fixtures))
  end
end
