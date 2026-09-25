defmodule SymphonyElixir.Claude.CLITest do
  # async: false — the tests rewrite the workflow file, PATH and GEARFLOW_WORKSPACE.
  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  alias SymphonyElixir.Claude.CLI

  setup do
    tmp = Path.join(System.tmp_dir!(), "claude-cli-test-#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    workspace = Path.join(Config.workspace_root(), "cli-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(tmp)
      File.rm_rf(workspace)
    end)

    {:ok, tmp: tmp, bin: bin, workspace: workspace}
  end

  # Writes the default test workflow with `command`, then injects the extra
  # `claude:` keys that the shared workflow helper does not expose.
  defp configure_claude!(command, extra_lines \\ []) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, claude_command: command)

    injected =
      path
      |> File.read!()
      |> String.replace("claude:\n", "claude:\n" <> Enum.map_join(extra_lines, "", &("  " <> &1 <> "\n")), global: false)

    File.write!(path, injected)
    WorkflowStore.force_reload()
    :ok
  end

  # A fake `claude` executable: records its argv (one per line) and runs `body`.
  defp fake_claude!(bin, name \\ "fake-claude", body) do
    path = Path.join(bin, name)
    args_file = Path.join(bin, "#{name}.args")

    File.write!(path, """
    #!/bin/sh
    for a in "$@"; do printf '%s\\n' "$a"; done > '#{args_file}'
    #{body}
    """)

    File.chmod!(path, 0o755)
    {path, args_file}
  end

  defp collect_events do
    parent = self()
    fn event -> send(parent, {:event, event}) end
  end

  defp received_events do
    receive do
      {:event, event} -> [event | received_events()]
    after
      0 -> []
    end
  end

  describe "run/3" do
    test "streams parsed events, tracks session id and usage, and skips unparseable lines", ctx do
      {cmd, args_file} =
        fake_claude!(ctx.bin, """
        echo '{"type":"system","subtype":"init","session_id":"sess-123"}'
        echo 'not json at all'
        echo '[1,2,3]'
        echo '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5}}}'
        echo '{"type":"result","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}'
        """)

      configure_claude!(cmd, [
        "model: \"claude-test-model\"",
        "dangerously_skip_permissions: true",
        "allowed_tools: [\"Bash(git:*)\", \"Read\"]"
      ])

      assert {:ok, result} = CLI.run("do it's thing", ctx.workspace, on_event: collect_events())
      assert result == %{session_id: "sess-123", exit_code: 0, usage: %{input_tokens: 20, output_tokens: 7, total_tokens: 27}}

      events = received_events()
      assert Enum.map(events, & &1.event_type) == [:session_started, :assistant, :result]

      args = args_file |> File.read!() |> String.split("\n", trim: true)
      # The prompt survives shell quoting intact, including its single quote.
      assert ["-p", "do it's thing", "--verbose", "--output-format", "stream-json" | _] = args
      assert "--dangerously-skip-permissions" in args
      assert ["--model", "claude-test-model"] == Enum.slice(args, Enum.find_index(args, &(&1 == "--model")), 2)
      assert Enum.chunk_every(args, 2, 1) |> Enum.count(&(&1 == ["--allowedTools", "Bash(git:*)"])) == 1
      assert Enum.chunk_every(args, 2, 1) |> Enum.count(&(&1 == ["--allowedTools", "Read"])) == 1
      assert "--strict-mcp-config" in args
    end

    test "uses the configured timeouts and a no-op event callback by default", ctx do
      {cmd, args_file} = fake_claude!(ctx.bin, ~s(echo '{"type":"result","session_id":"s-default"}'))
      configure_claude!(cmd)

      assert {:ok, %{session_id: "s-default", exit_code: 0, usage: nil}} = CLI.run("hi", ctx.workspace)

      args = args_file |> File.read!() |> String.split("\n", trim: true)
      refute "--dangerously-skip-permissions" in args
      refute "--model" in args
      refute "--allowedTools" in args
    end

    test "reassembles a line longer than the port line buffer", ctx do
      {cmd, _} =
        fake_claude!(ctx.bin, """
        printf '{"type":"assistant","session_id":"long","pad":"'
        head -c 1100000 /dev/zero | tr '\\000' 'a'
        printf '"}\\n'
        """)

      configure_claude!(cmd)

      assert {:ok, %{session_id: "long"}} = CLI.run("hi", ctx.workspace, on_event: collect_events())
      assert [%{"pad" => pad, event_type: :assistant}] = received_events()
      assert byte_size(pad) == 1_100_000
    end

    test "strips control characters the PTY wrapper prepends to a line", ctx do
      {cmd, _} = fake_claude!(ctx.bin, ~S(printf '\004\010{"type":"result","session_id":"ctl"}\n'))
      configure_claude!(cmd)

      assert {:ok, %{session_id: "ctl"}} = CLI.run("hi", ctx.workspace, on_event: collect_events())
      assert [%{event_type: :result}] = received_events()
    end

    test "passes extra words of the configured command before the generated args", ctx do
      {cmd, args_file} = fake_claude!(ctx.bin, "exit 0")
      configure_claude!("#{cmd} --extra-flag value")

      assert {:ok, %{session_id: nil, exit_code: 0}} = CLI.run("hi", ctx.workspace)
      assert ["--extra-flag", "value", "-p", "hi" | _] = args_file |> File.read!() |> String.split("\n", trim: true)
    end

    test "a blank configured command falls back to `claude` resolved from PATH", ctx do
      {_cmd, args_file} = fake_claude!(ctx.bin, "claude", "exit 0")
      configure_claude!("   ")

      old_path = System.get_env("PATH")
      System.put_env("PATH", ctx.bin <> ":" <> old_path)
      on_exit(fn -> System.put_env("PATH", old_path) end)

      assert {:ok, %{exit_code: 0}} = CLI.run("from path", ctx.workspace)
      assert ["-p", "from path" | _] = args_file |> File.read!() |> String.split("\n", trim: true)
    end

    test "returns a subprocess_exit error for a non-zero exit status", ctx do
      {cmd, _} = fake_claude!(ctx.bin, "echo '{\"type\":\"system\"}'; exit 3")
      configure_claude!(cmd)

      assert {:error, {:subprocess_exit, 3}} = CLI.run("hi", ctx.workspace)
    end

    test "returns :stall_timeout when the subprocess goes silent", ctx do
      marker = Path.join(ctx.tmp, "still-running")

      {cmd, _} =
        fake_claude!(ctx.bin, """
        echo '{"type":"system","subtype":"init","session_id":"s1"}'
        sleep 3
        touch '#{marker}'
        """)

      configure_claude!(cmd)

      assert {:error, :stall_timeout} =
               CLI.run("hi", ctx.workspace, stall_timeout_ms: 300, turn_timeout_ms: 10_000)

      # The process group was killed, so the script never reached its last line.
      Process.sleep(3_500)
      refute File.exists?(marker)
    end

    test "returns :stall_timeout immediately when the stall window is zero", ctx do
      {cmd, _} = fake_claude!(ctx.bin, "sleep 5")
      configure_claude!(cmd)

      assert {:error, :stall_timeout} = CLI.run("hi", ctx.workspace, stall_timeout_ms: 0, turn_timeout_ms: 10_000)
    end

    test "returns :turn_timeout when a silent turn outlasts the turn deadline", ctx do
      {cmd, _} = fake_claude!(ctx.bin, "sleep 5")
      configure_claude!(cmd)

      assert {:error, :turn_timeout} = CLI.run("hi", ctx.workspace, stall_timeout_ms: 10_000, turn_timeout_ms: 200)
    end

    test "returns :turn_timeout when a chatty turn outlasts the turn deadline", ctx do
      {cmd, _} =
        fake_claude!(ctx.bin, """
        yes '{"type":"assistant"}'
        """)

      configure_claude!(cmd)

      assert {:error, :turn_timeout} = CLI.run("hi", ctx.workspace, stall_timeout_ms: 10_000, turn_timeout_ms: 300)
    end
  end

  describe "resume/4" do
    test "passes --resume with the session id and omits model and allowed tools", ctx do
      {cmd, args_file} = fake_claude!(ctx.bin, ~s(echo '{"type":"result","session_id":"sess-9"}'))

      configure_claude!(cmd, [
        "model: \"claude-test-model\"",
        "dangerously_skip_permissions: true",
        "allowed_tools: [\"Read\"]"
      ])

      assert {:ok, %{session_id: "sess-9", exit_code: 0}} = CLI.resume("sess-9", "continue", ctx.workspace)

      args = args_file |> File.read!() |> String.split("\n", trim: true)
      assert ["--resume", "sess-9", "-p", "continue" | _] = args
      assert "--dangerously-skip-permissions" in args
      refute "--model" in args
      refute "--allowedTools" in args
    end
  end

  describe "workspace validation" do
    test "rejects a path that is not a directory" do
      missing = Path.join(Config.workspace_root(), "missing-#{System.unique_integer([:positive])}")
      assert {:error, {:invalid_workspace_cwd, :not_a_directory}} = CLI.run("hi", missing)
    end

    test "rejects a directory outside every allowed root", ctx do
      assert {:error, {:invalid_workspace_cwd, :outside_root}} = CLI.run("hi", ctx.tmp)
    end

    test "accepts a local-dev slot under $GEARFLOW_WORKSPACE", ctx do
      {cmd, _} = fake_claude!(ctx.bin, "exit 0")
      configure_claude!(cmd)

      slot = Path.join([ctx.tmp, "ws", "local-dev", "repo-slot1"])
      File.mkdir_p!(slot)

      old = System.get_env("GEARFLOW_WORKSPACE")
      System.put_env("GEARFLOW_WORKSPACE", Path.join(ctx.tmp, "ws"))
      on_exit(fn -> restore_env("GEARFLOW_WORKSPACE", old) end)

      assert {:ok, %{exit_code: 0}} = CLI.run("hi", slot)
    end
  end
end
