defmodule SymphonyElixir.Claude.SessionWatcherCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.SessionWatcher

  @moduletag :capture_log

  defp tmp_path, do: Path.join(System.tmp_dir!(), "sw-cov-#{System.unique_integer([:positive])}.jsonl")

  defp start(path) do
    test = self()
    {:ok, pid} = SessionWatcher.start_link(jsonl_path: path, on_event: &send(test, {:event, &1}), poll_interval_ms: 10)
    pid
  end

  defp end_turn, do: ~s({"type":"assistant","message":{"stop_reason":"end_turn"}}\n)

  test "a file that does not exist yet reads as empty until Claude creates it" do
    path = tmp_path()
    on_exit(fn -> File.rm(path) end)
    pid = start(path)

    assert {:error, :timeout} = SessionWatcher.wait_for_turn(pid, 30)
    File.write!(path, end_turn())
    assert {:ok, %{turn: 1, stop_reason: "end_turn"}} = SessionWatcher.wait_for_turn(pid, 1_000)
    assert :ok = SessionWatcher.stop(pid)
    refute Process.alive?(pid)
  end

  test "a turn that completed before the wait is returned immediately" do
    path = tmp_path()
    File.write!(path, end_turn())
    on_exit(fn -> File.rm(path) end)
    pid = start(path)

    assert_receive {:event, %{event_type: :assistant}}, 1_000
    assert SessionWatcher.completed_turns(pid) == 1
    assert {:ok, %{turn: 1}} = SessionWatcher.wait_for_turn(pid, 0)
  end

  test "unparseable lines are skipped without stopping the stream" do
    path = tmp_path()
    File.write!(path, "garbage\n[1]\n" <> end_turn())
    on_exit(fn -> File.rm(path) end)
    pid = start(path)

    assert {:ok, %{turn: 1}} = SessionWatcher.wait_for_turn(pid, 1_000)
    assert_received {:event, %{event_type: :assistant}}
    refute_received {:event, _}
  end

  test "an unreadable path keeps the watcher alive" do
    dir = Path.join(System.tmp_dir!(), "sw-cov-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    pid = start(dir)

    assert {:error, :timeout} = SessionWatcher.wait_for_turn(pid, 40)
    assert Process.alive?(pid)
  end

  test "stopping the watcher releases a pending waiter with a timeout" do
    path = tmp_path()
    on_exit(fn -> File.rm(path) end)
    pid = start(path)

    waiter = Task.async(fn -> SessionWatcher.wait_for_turn(pid, 60_000) end)
    wait_until_waiting(pid)
    :ok = SessionWatcher.stop(pid)

    assert Task.await(waiter, 1_000) == {:error, :timeout}
  end

  defp wait_until_waiting(pid) do
    if :sys.get_state(pid).waiters == [] do
      Process.sleep(5)
      wait_until_waiting(pid)
    end
  end
end
