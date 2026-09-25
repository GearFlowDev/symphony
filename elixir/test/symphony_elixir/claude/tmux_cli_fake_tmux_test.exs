defmodule SymphonyElixir.Claude.TmuxCLIFakeTmuxTest do
  # Drives TmuxCLI against a scripted fake `tmux` on PATH, so every tmux reply
  # (pane captures, failures, a missing server) is deterministic.
  # async: false — the tests rewrite PATH, env vars and the workflow file.
  use SymphonyElixir.TestSupport

  @moduletag :capture_log

  alias SymphonyElixir.Claude.TmuxCLI

  @fake_tmux """
  #!/bin/sh
  d="$FAKE_TMUX_DIR"
  printf '%s\\n' "$*" >> "$d/log"
  if [ -f "$d/fail" ]; then
    while IFS= read -r pat; do
      case "$*" in *"$pat"*) echo "boom: $1"; exit 7;; esac
    done < "$d/fail"
  fi
  case "$1" in
    has-session) [ -f "$d/alive" ] && exit 0; echo "can't find session"; exit 1;;
    new-session) touch "$d/alive"; exit 0;;
    kill-session) rm -f "$d/alive"; exit 0;;
    load-buffer) cp "$2" "$d/loaded"; exit 0;;
    capture-pane)
      n=$(( $(cat "$d/cap_n" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$d/cap_n"
      if [ -f "$d/pane.$n" ]; then cat "$d/pane.$n"; exit 0; fi
      if [ -f "$d/pane.$n.fail" ]; then exit 1; fi
      if [ -f "$d/pane" ]; then cat "$d/pane"; exit 0; fi
      exit 1;;
    list-sessions)
      if [ -f "$d/sessions" ]; then cat "$d/sessions"; exit 0; fi
      echo "no server running"; exit 1;;
    *) exit 0;;
  esac
  """

  @ready_pane "❯ \n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "fake-tmux-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    tmux = Path.join(bin, "tmux")
    File.write!(tmux, @fake_tmux)
    File.chmod!(tmux, 0o755)

    old_path = System.get_env("PATH")
    old_dir = System.get_env("FAKE_TMUX_DIR")
    System.put_env("PATH", bin <> ":" <> old_path)
    System.put_env("FAKE_TMUX_DIR", dir)

    workspace = Path.join(Config.workspace_root(), "tmux-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    prefix = "faketmux#{System.unique_integer([:positive])}"
    configure_claude!(prefix)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      restore_env("FAKE_TMUX_DIR", old_dir)
      File.rm_rf(dir)
      File.rm_rf(workspace)
    end)

    {:ok, dir: dir, bin: bin, workspace: workspace, prefix: prefix}
  end

  defp configure_claude!(prefix, extra_lines \\ []) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, claude_command: "claude-bin")

    lines =
      [
        "tmux_session_prefix: \"#{prefix}\"",
        "tmux_startup_delay_ms: 0",
        "tmux_paste_settle_ms: 0",
        "tmux_ready_poll_interval_ms: 5"
      ] ++ extra_lines

    injected =
      path
      |> File.read!()
      |> String.replace("claude:\n", "claude:\n" <> Enum.map_join(lines, "", &("  " <> &1 <> "\n")), global: false)

    File.write!(path, injected)
    WorkflowStore.force_reload()
    :ok
  end

  defp tmux_log(dir) do
    case File.read(Path.join(dir, "log")) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp put_panes(dir, panes) do
    panes
    |> Enum.with_index(1)
    |> Enum.each(fn
      {:fail, i} -> File.write!(Path.join(dir, "pane.#{i}.fail"), "")
      {text, i} -> File.write!(Path.join(dir, "pane.#{i}"), text)
    end)
  end

  defp fail_on(dir, patterns), do: File.write!(Path.join(dir, "fail"), Enum.join(patterns, "\n") <> "\n")

  defp session_id, do: "sid-#{System.unique_integer([:positive])}"

  defp sysprompt_path(sid), do: Path.join(System.tmp_dir!(), "symphony-#{sid}-sysprompt.txt")

  describe "start_session/3" do
    test "launches claude, answers the trust dialog via its cursor, and waits for the input", ctx do
      configure_claude!(ctx.prefix, ["model: \"cfg-model\"", "dangerously_skip_permissions: true"])
      old_key = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "lin_test_key")
      on_exit(fn -> restore_env("LINEAR_API_KEY", old_key) end)

      trust_no = " Do you trust this folder?\n ❯ No, exit\n   Yes, I trust this folder\n"
      trust_yes = " Do you trust the files here?\n   No, exit\n ❯ Yes, I trust this folder\n"
      # pane_state(no) → Down; pane_state(yes) → answer capture fails → retry;
      # pane_state(yes) → Enter; then pending; then ready.
      put_panes(ctx.dir, [trust_no, trust_no, trust_yes, :fail, trust_yes, trust_yes, "Loading...", @ready_pane])

      sid = session_id()
      on_exit(fn -> File.rm(sysprompt_path(sid)) end)

      assert {:ok, handle} =
               TmuxCLI.start_session(ctx.workspace, sid, append_system_prompt: "line one\nline two")

      name = "#{ctx.prefix}-#{sid}"
      assert handle == %{session_id: sid, session_name: name, workspace: Path.expand(ctx.workspace)}

      log = tmux_log(ctx.dir)
      [new_session | _] = log
      assert new_session =~ "new-session -d -s #{name} -x 200 -y 50 -c #{Path.expand(ctx.workspace)}"
      assert new_session =~ "-e LINEAR_API_KEY=lin_test_key"
      assert new_session =~ "-e SYMPHONY_SCRIPTS="

      launch = Enum.find(log, &String.contains?(&1, "unset CLAUDECODE"))
      assert launch =~ "claude-bin --session-id #{sid} --tools 'Agent,Bash,Edit,Read,Write,Glob,Grep'"
      assert launch =~ ~s(--mcp-config '{"mcpServers":{}}' --strict-mcp-config)
      assert launch =~ ~s(--append-system-prompt "$\(cat '#{sysprompt_path(sid)}'\)")
      assert launch =~ "--dangerously-skip-permissions --model cfg-model"
      assert File.read!(sysprompt_path(sid)) == "line one\nline two"

      keys = Enum.filter(log, &String.starts_with?(&1, "send-keys -t #{name}: "))

      assert Enum.map(keys, &String.replace_prefix(&1, "send-keys -t #{name}: ", "")) |> Enum.reject(&(&1 =~ "CLAUDECODE")) ==
               ["Enter", "Down", "Enter"]
    end

    test "passes an empty tools list and a model override, without a system prompt", ctx do
      File.write!(Path.join(ctx.dir, "pane"), "❯ \n  1234 tokens\n")
      sid = session_id()

      assert {:ok, _} = TmuxCLI.start_session(ctx.workspace, sid, tools: "", model: "opt-model", append_system_prompt: "")

      launch = ctx.dir |> tmux_log() |> Enum.find(&String.contains?(&1, "unset CLAUDECODE"))
      assert launch =~ "--tools '' --mcp-config"
      assert launch =~ "--model opt-model"
      refute launch =~ "--append-system-prompt"
      refute launch =~ "--dangerously-skip-permissions"
      refute File.exists?(sysprompt_path(sid))
    end

    test "returns :tmux_not_found when tmux is not on PATH", ctx do
      System.put_env("PATH", Path.join(ctx.dir, "empty-bin"))
      assert {:error, :tmux_not_found} = TmuxCLI.start_session(ctx.workspace, session_id())
    end

    test "reports a failed new-session and tears the session down", ctx do
      fail_on(ctx.dir, ["new-session"])
      sid = session_id()

      assert {:error, {:tmux_new_session_failed, 7, "boom: new-session"}} = TmuxCLI.start_session(ctx.workspace, sid)
      assert "kill-session -t #{ctx.prefix}-#{sid}" in tmux_log(ctx.dir)
    end

    test "reports a failed launch keystroke and kills the half-started session", ctx do
      fail_on(ctx.dir, ["CLAUDECODE"])
      sid = session_id()

      assert {:error, {:tmux_launch_failed, 7, "boom: send-keys"}} = TmuxCLI.start_session(ctx.workspace, sid)
      refute File.exists?(Path.join(ctx.dir, "alive"))
    end

    test "returns :session_died_during_startup when the tmux session vanishes", ctx do
      fail_on(ctx.dir, ["has-session"])
      assert {:error, :session_died_during_startup} = TmuxCLI.start_session(ctx.workspace, session_id())
    end

    test "returns :ready_timeout when the TUI never becomes ready", ctx do
      File.write!(Path.join(ctx.dir, "pane"), "❯ 1. Some unknown modal\n")

      assert {:error, :ready_timeout} =
               TmuxCLI.start_session(ctx.workspace, session_id(), ready_timeout_ms: 60, ready_poll_interval_ms: 5)

      refute File.exists?(Path.join(ctx.dir, "alive"))
    end

    test "treats a failing pane capture as still pending", ctx do
      # No pane file at all: every capture-pane fails.
      assert {:error, :ready_timeout} =
               TmuxCLI.start_session(ctx.workspace, session_id(), ready_timeout_ms: 40, ready_poll_interval_ms: 5)

      assert Enum.any?(tmux_log(ctx.dir), &String.starts_with?(&1, "capture-pane"))
    end

    test "accepts a local-dev slot under $GEARFLOW_WORKSPACE", ctx do
      File.write!(Path.join(ctx.dir, "pane"), @ready_pane)
      slot = Path.join([ctx.dir, "ws", "local-dev", "repo-slot2"])
      File.mkdir_p!(slot)

      old = System.get_env("GEARFLOW_WORKSPACE")
      System.put_env("GEARFLOW_WORKSPACE", Path.join(ctx.dir, "ws"))
      on_exit(fn -> restore_env("GEARFLOW_WORKSPACE", old) end)

      assert {:ok, %{workspace: ^slot}} = TmuxCLI.start_session(slot, session_id())
    end
  end

  describe "send_prompt/3" do
    setup ctx do
      sid = session_id()
      File.touch!(Path.join(ctx.dir, "alive"))
      handle = %{session_id: sid, session_name: "#{ctx.prefix}-#{sid}", workspace: ctx.workspace}
      on_exit(fn -> File.rm(Path.join(System.tmp_dir!(), "symphony-#{sid}-1.txt")) end)
      {:ok, handle: handle}
    end

    test "pastes the prompt as one bracketed paste and submits it", %{handle: handle} = ctx do
      prompt = "please fix the flaky test\nand then open a PR for it"
      File.write!(Path.join(ctx.dir, "pane"), "❯ please fix the flaky test\n  and then open a PR for it\n")

      assert :ok = TmuxCLI.send_prompt(handle, prompt, 1)
      assert File.read!(Path.join(ctx.dir, "loaded")) == prompt

      pane = "#{handle.session_name}:"

      assert tmux_log(ctx.dir) == [
               "has-session -t #{handle.session_name}",
               "send-keys -t #{pane} -N 25 C-u",
               "load-buffer #{Path.join(System.tmp_dir!(), "symphony-#{handle.session_id}-1.txt")}",
               "paste-buffer -p -t #{pane}",
               "capture-pane -t #{pane} -p",
               "send-keys -t #{pane} Enter"
             ]
    end

    test "re-pastes when the first paste does not show up in the input", %{handle: handle} = ctx do
      prompt = "a short single line prompt to deliver"
      put_panes(ctx.dir, ["❯ \n", :fail])
      File.write!(Path.join(ctx.dir, "pane"), "❯ #{prompt}\n")

      assert :ok = TmuxCLI.send_prompt(handle, prompt, 1)
      assert ctx.dir |> tmux_log() |> Enum.count(&String.starts_with?(&1, "paste-buffer")) == 3
    end

    test "returns :session_not_alive when the session is gone", %{handle: handle} = ctx do
      File.rm!(Path.join(ctx.dir, "alive"))
      assert {:error, :session_not_alive} = TmuxCLI.send_prompt(handle, "hi", 1)
      refute Enum.any?(tmux_log(ctx.dir), &String.starts_with?(&1, "load-buffer"))
    end

    test "reports a failed paste step", %{handle: handle} = ctx do
      fail_on(ctx.dir, ["load-buffer"])
      assert {:error, {:tmux_paste_failed, 7, "boom: load-buffer"}} = TmuxCLI.send_prompt(handle, "hi", 1)
    end

    test "reports a failed Enter after a visible paste", %{handle: handle} = ctx do
      fail_on(ctx.dir, [": Enter"])
      File.write!(Path.join(ctx.dir, "pane"), "❯ hello there\n")
      assert {:error, {:tmux_send_failed, 7, "boom: send-keys"}} = TmuxCLI.send_prompt(handle, "hello there", 1)
    end

    test "returns the file error when the prompt file cannot be written", ctx do
      sid = "no-such-dir/#{System.unique_integer([:positive])}"
      File.touch!(Path.join(ctx.dir, "alive"))
      handle = %{session_id: sid, session_name: "#{ctx.prefix}-x", workspace: ctx.workspace}
      assert {:error, :enoent} = TmuxCLI.send_prompt(handle, "hi", 1)
    end
  end

  describe "stop_session/1 and alive?/1" do
    test "sends /exit to a live session, kills it and removes its prompt files", ctx do
      sid = session_id()
      name = "#{ctx.prefix}-#{sid}"
      File.touch!(Path.join(ctx.dir, "alive"))
      prompt_file = Path.join(System.tmp_dir!(), "symphony-#{sid}-1.txt")
      File.write!(prompt_file, "prompt")
      handle = %{session_id: sid, session_name: name, workspace: ctx.workspace}

      assert TmuxCLI.alive?(handle)
      assert :ok = TmuxCLI.stop_session(handle)
      refute TmuxCLI.alive?(handle)
      refute File.exists?(prompt_file)

      assert Enum.filter(tmux_log(ctx.dir), &String.starts_with?(&1, ["send-keys", "kill-session"])) == [
               "send-keys -t #{name}: /exit",
               "send-keys -t #{name}: Enter",
               "kill-session -t #{name}"
             ]
    end

    test "only kills a session that is already gone", ctx do
      sid = session_id()
      name = "#{ctx.prefix}-#{sid}"
      assert :ok = TmuxCLI.stop_session(%{session_id: sid, session_name: name, workspace: ctx.workspace})
      assert tmux_log(ctx.dir) == ["has-session -t #{name}", "kill-session -t #{name}"]
    end

    test "alive? is false when the tmux binary cannot be run", ctx do
      System.put_env("PATH", Path.join(ctx.dir, "empty-bin"))
      refute TmuxCLI.alive?("anything")
    end
  end

  describe "reap_orphan_sessions_except/2" do
    test "reaps prefixed sessions not kept, honouring the age floor", ctx do
      now = System.os_time(:second)
      p = ctx.prefix

      File.write!(Path.join(ctx.dir, "sessions"), """
      #{p}-old\t#{now - 600}
      #{p}-young\t#{now - 5}
      #{p}-keep\t#{now - 600}
      #{p}-noage
      #{p}-badage\tnot-a-number
      other-session\t#{now - 600}
      """)

      old_file = Path.join(System.tmp_dir!(), "symphony-old-1.txt")
      File.write!(old_file, "x")
      on_exit(fn -> File.rm(old_file) end)

      assert TmuxCLI.reap_orphan_sessions_except(MapSet.new(["keep"]), prefix: p, min_age_seconds: 60) == ["#{p}-old"]
      refute File.exists?(old_file)

      assert TmuxCLI.reap_orphan_sessions_except(["keep"], prefix: p) ==
               ["#{p}-old", "#{p}-young", "#{p}-noage", "#{p}-badage"]
    end

    test "uses the configured prefix by default", ctx do
      File.write!(Path.join(ctx.dir, "sessions"), "#{ctx.prefix}-abc\t1\nsymphony-zzz\t1\n")
      assert TmuxCLI.reap_orphan_sessions() == ["#{ctx.prefix}-abc"]
    end

    test "returns [] when no tmux server is running" do
      assert TmuxCLI.reap_orphan_sessions_except([]) == []
    end
  end

  describe "await_jsonl/2 defaults" do
    test "polls with the configured interval and timeout", ctx do
      base = Path.join(ctx.dir, "projects")
      configure_claude!(ctx.prefix, ["tmux_ready_timeout_ms: 30", "tmux_jsonl_base_path: \"#{base}\""])

      assert {:error, :not_found} = TmuxCLI.await_jsonl("missing-session")

      File.mkdir_p!(Path.join(base, "-proj"))
      File.write!(Path.join([base, "-proj", "present.jsonl"]), "")
      assert {:ok, path} = TmuxCLI.await_jsonl("present")
      assert path == Path.join([base, "-proj", "present.jsonl"])
    end
  end

  describe "session environment" do
    test "omits unset passthrough vars but always sets SYMPHONY_SCRIPTS", ctx do
      File.write!(Path.join(ctx.dir, "pane"), @ready_pane)

      for var <- ~w(LINEAR_API_KEY LINEAR_API_KEY_AUTOMATION) do
        old = System.get_env(var)
        System.delete_env(var)
        on_exit(fn -> restore_env(var, old) end)
      end

      assert {:ok, _} = TmuxCLI.start_session(ctx.workspace, session_id())
      [new_session | _] = tmux_log(ctx.dir)
      refute new_session =~ "LINEAR_API_KEY"
      assert new_session =~ ~r{-e SYMPHONY_SCRIPTS=\S+/priv/scripts/$}
    end
  end

  describe "pure helpers" do
    test "paste_landed? falls back to the pane tail when no input marker is visible" do
      pane = Enum.map_join(1..30, "\n", &"transcript line #{&1}") <> "\n> deliver this short prompt\n\n"
      assert TmuxCLI.paste_landed?(pane, "deliver this short prompt")
      refute TmuxCLI.paste_landed?(pane, "transcript line 1 is out of the tail window")
    end

    test "trust_cursor skips a cursor line on an unrecognised option" do
      assert TmuxCLI.trust_cursor(" ❯ Maybe later\n   Yes, I trust this folder\n") == :unknown
    end
  end

  describe "kill_by_session_id/1" do
    test "kills the prefixed session and ignores blank ids", ctx do
      assert :ok = TmuxCLI.kill_by_session_id("abc")
      assert :ok = TmuxCLI.kill_by_session_id("")
      assert tmux_log(ctx.dir) == ["kill-session -t #{ctx.prefix}-abc"]
    end
  end
end
