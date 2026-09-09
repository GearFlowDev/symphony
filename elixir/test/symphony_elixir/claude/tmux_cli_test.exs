defmodule SymphonyElixir.Claude.TmuxCLITest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.TmuxCLI
  alias SymphonyElixir.Config

  describe "session_jsonl_path/1" do
    test "returns :not_found when no JSONL exists for the session id" do
      assert {:error, :not_found} = TmuxCLI.session_jsonl_path("00000000-no-such-session")
    end

    test "finds the JSONL by its unique filename regardless of project-dir escaping" do
      session_id = "test-#{System.unique_integer([:positive])}"
      base = Path.expand(Config.claude_tmux_jsonl_base_path())

      # A project dir whose name contains characters Claude Code's escaping would
      # mangle (underscores -> dashes). Find-by-filename must not care.
      project_dir = Path.join(base, "-Test-ck-code-some_repo_#{System.unique_integer([:positive])}")
      jsonl = Path.join(project_dir, "#{session_id}.jsonl")
      File.mkdir_p!(project_dir)
      File.write!(jsonl, "")
      on_exit(fn -> File.rm_rf!(project_dir) end)

      assert {:ok, ^jsonl} = TmuxCLI.session_jsonl_path(session_id)
    end
  end

  describe "await_jsonl/2" do
    test "returns :not_found after the timeout when the file never appears" do
      assert {:error, :not_found} =
               TmuxCLI.await_jsonl("never-#{System.unique_integer([:positive])}",
                 poll_interval_ms: 10,
                 timeout_ms: 50
               )
    end

    test "returns {:ok, path} once the file appears" do
      session_id = "await-#{System.unique_integer([:positive])}"
      base = Path.expand(Config.claude_tmux_jsonl_base_path())
      project_dir = Path.join(base, "-Test-await-#{System.unique_integer([:positive])}")
      jsonl = Path.join(project_dir, "#{session_id}.jsonl")
      File.mkdir_p!(project_dir)
      File.write!(jsonl, "")
      on_exit(fn -> File.rm_rf!(project_dir) end)

      assert {:ok, ^jsonl} =
               TmuxCLI.await_jsonl(session_id, poll_interval_ms: 10, timeout_ms: 200)
    end
  end

  describe "reap_orphan_sessions/1" do
    @describetag :tmux

    # Tagged :tmux — these drive a real tmux server. Exclude with
    # `--exclude tmux` on hosts without tmux installed.
    setup do
      # Use a unique, test-only prefix so we never touch real symphony sessions.
      prefix = "symphonytest#{System.unique_integer([:positive])}"
      {:ok, prefix: prefix}
    end

    defp kill_on_exit(name) do
      on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true) end)
    end

    test "kills sessions matching the prefix and reports them", %{prefix: prefix} do
      name = "#{prefix}-#{System.unique_integer([:positive])}"
      kill_on_exit(name)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == [name]
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)
      assert code != 0
    end

    test "leaves sessions that do not match the prefix", %{prefix: prefix} do
      other = "unrelated-#{System.unique_integer([:positive])}"
      kill_on_exit(other)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", other], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == []
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", other], stderr_to_stdout: true)
    end

    test "removes the reaped session's prompt temp files", %{prefix: prefix} do
      session_id = "#{System.unique_integer([:positive])}"
      name = "#{prefix}-#{session_id}"
      kill_on_exit(name)
      tmp = Path.join(System.tmp_dir!(), "symphony-#{session_id}-1.txt")
      File.write!(tmp, "prompt")
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)

      assert TmuxCLI.reap_orphan_sessions(prefix) == [name]
      refute File.exists?(tmp)
    end
  end

  describe "start_session/3 workspace validation" do
    test "rejects a workspace outside the configured roots" do
      assert {:error, {:invalid_workspace_cwd, :outside_root}} =
               TmuxCLI.start_session("/etc", "irrelevant-session-id")
    end

    test "rejects a workspace that is not a directory" do
      assert {:error, {:invalid_workspace_cwd, :not_a_directory}} =
               TmuxCLI.start_session(
                 Path.join(Config.workspace_root(), "does-not-exist-#{System.unique_integer([:positive])}"),
                 "irrelevant-session-id"
               )
    end
  end

  describe "reap_orphan_sessions_except/2 and kill_by_session_id/1" do
    @describetag :tmux

    setup do
      prefix = "symphonytest#{System.unique_integer([:positive])}"
      {:ok, prefix: prefix}
    end

    defp new_session(name) do
      on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true) end)
      {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name], stderr_to_stdout: true)
      name
    end

    test "keeps sessions whose session_id is in the keep set", %{prefix: prefix} do
      keep_id = "#{System.unique_integer([:positive])}"
      drop_id = "#{System.unique_integer([:positive])}"
      keep_name = new_session("#{prefix}-#{keep_id}")
      drop_name = new_session("#{prefix}-#{drop_id}")

      assert TmuxCLI.reap_orphan_sessions_except([keep_id], prefix: prefix) == [drop_name]
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", keep_name], stderr_to_stdout: true)
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", drop_name], stderr_to_stdout: true)
      assert code != 0
    end

    test "does not reap a young session when min_age_seconds is set", %{prefix: prefix} do
      # The race guard: a just-launched worker's session exists before its
      # session_id reaches the running map, so a grace window must spare it.
      name = new_session("#{prefix}-#{System.unique_integer([:positive])}")

      assert TmuxCLI.reap_orphan_sessions_except([], prefix: prefix, min_age_seconds: 120) == []
      assert {_, 0} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)

      # Same session reaps once the age floor is removed.
      assert TmuxCLI.reap_orphan_sessions_except([], prefix: prefix) == [name]
    end

    test "kill_by_session_id kills the matching session and is idempotent" do
      # kill_by_session_id derives the name from the configured prefix, so build
      # the session under that same prefix (unique id avoids any real session).
      prefix = Config.claude_tmux_session_prefix()
      session_id = "killtest-#{System.unique_integer([:positive])}"
      name = new_session("#{prefix}-#{session_id}")

      assert :ok = TmuxCLI.kill_by_session_id(session_id)
      assert {_, code} = System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true)
      assert code != 0
      # Idempotent: killing an already-gone session is still :ok.
      assert :ok = TmuxCLI.kill_by_session_id(session_id)
      assert :ok = TmuxCLI.kill_by_session_id(nil)
    end
  end

  describe "paste_landed?/2" do
    # Pane fixtures mirror real `capture-pane -p` output from Claude Code 2.1.266
    # (probed 2026-09-09): the input box sits between two rule lines, starts with
    # the "❯" marker, and a multi-line bracketed paste collapses into a
    # "[Pasted text #N +L lines]" placeholder where L is the newline count.
    @rule String.duplicate("─", 40)

    defp pane(input_lines, transcript \\ []) do
      Enum.join(
        transcript ++ [@rule] ++ input_lines ++ [@rule, "  ⏵⏵ bypass permissions on (shift+tab to cycle)", "", "", ""],
        "\n"
      )
    end

    test "accepts a collapsed placeholder whose line count matches the prompt" do
      prompt = Enum.map_join(0..404, "\n", &"- row #{&1}: lorem ipsum")
      assert TmuxCLI.paste_landed?(pane(["❯ [Pasted text #69 +404 lines]"]), prompt)
    end

    test "rejects a placeholder with a smaller line count (paste lost its head)" do
      prompt = Enum.map_join(0..404, "\n", &"- row #{&1}: lorem ipsum")
      refute TmuxCLI.paste_landed?(pane(["❯ [Pasted text #69 +6 lines]"]), prompt)
    end

    test "rejects a literal tail-only delivery even though the suffix is visible" do
      # The GEA-7669 failure: 20 KB prompt, only its last ~390 chars landed.
      head = "# Symphony Agent Workflow\n\nYou are a senior engineer at Gearflow.\n" <> String.duplicate("- row: work item\n", 200)
      tail = "Escalate only when a row is genuinely impossible to close as written:\n- Missing backend / data / design\n- Broken slot"
      prompt = head <> tail

      pane_output =
        pane([
          "❯ Escalate only when a row is genuinely impossible to close as written:",
          "  - Missing backend / data / design",
          "  - Broken slot"
        ])

      refute TmuxCLI.paste_landed?(pane_output, prompt)
    end

    test "accepts a short prompt rendered literally when both ends are visible" do
      prompt = "first line of a short prompt\nsecond line of a short prompt"
      assert TmuxCLI.paste_landed?(pane(["❯ first line of a short prompt", "  second line of a short prompt"]), prompt)
    end

    test "tolerates the TUI wrapping a long literal line mid-word" do
      prompt = "line one " <> String.duplicate("alpha beta gamma delta ", 13) <> "\nline three end marker here"

      pane_output =
        pane([
          "❯ line one alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta alp",
          "  ha beta gamma delta alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta",
          "  alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta",
          "  line three end marker here"
        ])

      assert TmuxCLI.paste_landed?(pane_output, prompt)
    end

    test "ignores a previous turn's submitted placeholder in the transcript" do
      # Continuation prompts share a newline count turn after turn, and a short
      # reply can leave the previous turn's "> [Pasted text]" line near the
      # bottom. An empty input box must still read as not-landed.
      prompt = Enum.map_join(1..11, "\n", &"continuation line #{&1}")

      pane_output =
        pane(
          ["❯ "],
          ["> [Pasted text #2 +10 lines]", "", "⏺ Ending the turn.", ""]
        )

      refute TmuxCLI.paste_landed?(pane_output, prompt)
    end

    test "rejects an empty input box" do
      refute TmuxCLI.paste_landed?(pane(["❯ "]), "some prompt text that never arrived\nsecond line")
    end
  end

  describe "trust_cursor/1" do
    test "detects the 2.1.26x layout where 'No, exit' is preselected" do
      output = """
       Quick safety check: Is this a project you created or one you trust?
       ❯ No, exit
         Yes, I trust this folder
       Enter to confirm · Esc to cancel
      """

      assert TmuxCLI.trust_cursor(output) == :no
    end

    test "detects the cursor on the Yes option, numbered or not" do
      assert TmuxCLI.trust_cursor("   No, exit\n ❯ Yes, I trust this folder\n") == :yes
      assert TmuxCLI.trust_cursor(" ❯ 1. Yes, proceed\n   2. No, exit\n") == :yes
    end

    test "returns :unknown when no recognisable option is under the cursor" do
      assert TmuxCLI.trust_cursor("Do you trust the files in this folder?\n") == :unknown
    end
  end
end
