defmodule SymphonyElixir.Claude.OneShotCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.{OneShot, SessionWatcher}

  @moduletag :capture_log

  # Writes one queued JSONL fixture per prompt; the path and the start/await
  # results are scripted through the (test) process dictionary.
  defmodule Session do
    @moduledoc false
    def start_session(_workspace, session_id, opts) do
      Process.put(:start_opts, opts)
      Process.get(:start_result, {:ok, session_id})
    end

    def send_prompt(sid, prompt, 1) do
      Process.put(:prompts, Process.get(:prompts, []) ++ [prompt])
      [fixture | rest] = Process.get(:fixtures, [""])
      Process.put(:fixtures, rest)
      File.write!(path(sid), fixture)
      :ok
    end

    def await_jsonl(sid), do: Process.get(:await_result, {:ok, path(sid)})
    def stop_session(sid), do: File.rm(path(sid))

    def path(sid), do: Path.join(System.tmp_dir!(), "oneshot-cov-#{sid}.jsonl")
  end

  defmodule OkWatcher do
    @moduledoc false
    def start_link(_opts), do: {:ok, :w}
    def wait_for_turn(:w, _timeout), do: {:ok, %{}}
    def stop(:w), do: :ok
  end

  defp line(text, extra \\ %{}) do
    Map.merge(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}}, extra)
    |> Jason.encode!()
  end

  defp opts(fixtures, extra \\ []) do
    Process.put(:fixtures, fixtures)
    Keyword.merge([session_module: Session, watcher_module: OkWatcher, cwd: System.tmp_dir!()], extra)
  end

  test "works end to end with the real SessionWatcher and passes the model through" do
    jsonl = Enum.join([~s({"type":"system","subtype":"init"}), line("from the watcher")], "\n") <> "\n"

    assert OneShot.request("sys", "q", opts([jsonl], watcher_module: SessionWatcher, timeout_ms: 2_000, model: "opus")) ==
             {:ok, "from the watcher"}

    assert Keyword.get(Process.get(:start_opts), :model) == "opus"
  end

  test "skips garbage lines and non-assistant events when reading the reply" do
    jsonl = Enum.join(["not json", ~s({"type":"user","message":{"content":[{"type":"text","text":"user said"}]}}), line(" answer "), ~s({"type":"result"})], "\n")
    assert OneShot.request("sys", "q", opts([jsonl])) == {:ok, "answer"}
  end

  test "a failed session start is reported" do
    Process.put(:start_result, {:error, :no_tmux})
    assert OneShot.request("sys", "q", opts([])) == {:error, {:start_session_failed, :no_tmux}}
    assert OneShot.request_json("sys", "q", opts([])) == {:error, {:start_session_failed, :no_tmux}}
  end

  test "a JSONL that never appears is reported" do
    Process.put(:await_result, {:error, :jsonl_timeout})
    assert OneShot.request("sys", "q", opts([line("x")])) == {:error, :jsonl_timeout}
  end

  test "an unreadable JSONL is reported" do
    Process.put(:await_result, {:ok, "/nonexistent/dir/oneshot.jsonl"})
    assert OneShot.request("sys", "q", opts([line("x")])) == {:error, {:jsonl_read_failed, :enoent}}
  end

  test "request_json gives up after three non-JSON replies, nudging each retry" do
    assert OneShot.request_json("sys", "grade", opts([line("nope"), line("still no"), line("no again")])) ==
             {:error, {:json_decode, "no again"}}

    [first, second, third] = Process.get(:prompts)
    assert first == "grade"
    assert second =~ "[reminder] Reply with ONLY a single JSON object"
    assert third =~ "[reminder]"
  end
end
