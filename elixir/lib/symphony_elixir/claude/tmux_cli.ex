defmodule SymphonyElixir.Claude.TmuxCLI do
  @moduledoc """
  Hosts a long-running, interactive Claude Code session inside a dedicated tmux
  session and delivers prompts to it.

  This replaces the `claude -p` (print mode) execution in
  `SymphonyElixir.Claude.CLI`. Print mode bills against Anthropic's programmatic
  credit pool; a long-running interactive `claude` bills against the plan.

  The session is created once per issue run. Prompts are delivered via
  `tmux load-buffer` + `paste-buffer -p` (one bracketed paste, reliable for any
  prompt size — see `send_prompt/3`). The structured event stream is NOT
  read from stdout here — interactive Claude Code writes the full event stream to
  a JSONL file, which `SymphonyElixir.Claude.SessionWatcher` tails. This module
  only owns the tmux/process lifecycle and prompt delivery.

  ## Session id

  The caller assigns a UUID and passes it to `claude --session-id`. That id is
  both the tmux session suffix and the JSONL filename, so we never have to derive
  Claude Code's escaped project-directory path (the escaping rule is more than
  `/`→`-`: underscores also become dashes). `session_jsonl_path/1` finds the file
  by its globally unique name instead.
  """

  require Logger
  alias SymphonyElixir.Config

  # Restrict to core tools only. MCP plugins (Playwright, Linear, Tidewave) add
  # 50-80 tools that consume hundreds of thousands of context tokens. Agents use
  # curl/bash for the Linear API and npx for Playwright instead.
  @agent_tools "Agent,Bash,Edit,Read,Write,Glob,Grep"
  @mcp_config_json "{\"mcpServers\":{}}"

  # The TUI can show its input prompt (`❯`) before it reliably accepts a pasted
  # buffer (e.g. while the welcome splash is still rendering at startup). A paste
  # sent in that window is silently dropped, so we verify the text landed in the
  # input and re-paste a few times before giving up.
  @paste_attempts 8

  @type session_handle :: %{
          session_id: String.t(),
          session_name: String.t(),
          workspace: Path.t()
        }

  @doc """
  Start a tmux-hosted interactive Claude Code session in `workspace`, using the
  caller-provided `session_id` (a valid UUID).

  Blocks until the TUI is ready (the `❯` prompt appears) or `ready_timeout_ms`
  elapses. Returns a session handle for the other functions in this module.

  Options:
    * `:tools` — comma-separated allowed-tools string passed to `--tools`.
      Defaults to the worker toolset; pass `""` for a no-tools reasoning session.
    * `:append_system_prompt` — extra system prompt appended via
      `--append-system-prompt` (multi-line safe).
    * `:model` — `--model` override; falls back to `Config.claude_model/0`.
    * `:ready_timeout_ms`, `:ready_poll_interval_ms` — readiness polling.
  """
  @spec start_session(Path.t(), String.t(), keyword()) ::
          {:ok, session_handle()} | {:error, term()}
  def start_session(workspace, session_id, opts \\ []) do
    with :ok <- validate_workspace(workspace),
         :ok <- ensure_tmux() do
      expanded = Path.expand(workspace)
      session_name = session_name(session_id)

      with :ok <- new_tmux_session(session_name, expanded),
           :ok <- launch_claude(session_name, session_id, opts),
           :ok <- wait_for_ready(session_name, opts) do
        Logger.info("Started tmux Claude session session_id=#{session_id} session_name=#{session_name} workspace=#{expanded}")

        {:ok, %{session_id: session_id, session_name: session_name, workspace: expanded}}
      else
        {:error, reason} ->
          # Tear down a half-started session so we don't leak it.
          kill_session(session_name)
          {:error, reason}
      end
    end
  end

  @doc """
  Deliver `prompt` to the running session and submit it.

  Uses `load-buffer` + `paste-buffer -p` so arbitrarily large / multi-line
  prompts arrive intact, then sends Enter as a separate keystroke (tmux requires
  this). `-p` wraps the text in bracketed-paste markers unconditionally. Without
  them the TUI has to guess where a burst of keystrokes ends: Claude Code
  2.1.265+ no longer switches the pane into bracketed-paste mode itself, and its
  heuristic dropped the head of large pastes — workers received only the last
  few hundred characters of a 20 KB prompt (GEA-7669, 2026-09-09) — while a
  2-line paste submitted at the newline. With the markers every size lands as
  one unit, and a multi-line paste collapses to "[Pasted text #N +L lines]".

  A short settle delay between paste and Enter is essential: the TUI processes the
  bracketed paste on its next render frame, and an Enter sent in the same frame is
  dropped (submitting nothing). `tmux_paste_settle_ms` controls the gap.
  """
  @spec send_prompt(session_handle(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def send_prompt(%{session_name: session_name, session_id: session_id}, prompt, turn)
      when is_binary(prompt) and is_integer(turn) do
    if alive?(session_name) do
      prompt_file = prompt_file_path(session_id, turn)

      with :ok <- File.write(prompt_file, prompt),
           :ok <- paste_until_visible(session_name, prompt_file, prompt, @paste_attempts),
           {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "Enter"]) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        {output, code} -> {:error, {:tmux_send_failed, code, String.trim(output)}}
      end
    else
      {:error, :session_not_alive}
    end
  end

  @doc """
  Stop the session: send `/exit` to let Claude close cleanly, then kill the tmux
  session (idempotent) and remove this session's prompt temp files.
  """
  @spec stop_session(session_handle()) :: :ok
  def stop_session(%{session_name: session_name, session_id: session_id}) do
    if alive?(session_name) do
      tmux(["send-keys", "-t", pane(session_name), "/exit"])
      tmux(["send-keys", "-t", pane(session_name), "Enter"])
      Process.sleep(2_000)
    end

    kill_session(session_name)
    cleanup_prompt_files(session_id)
    :ok
  end

  @doc """
  Force-kill the tmux session for `session_id` without the graceful `/exit`
  wait. Idempotent — safe when the session is already gone.

  The orchestrator calls this when it terminates a worker (stall restart,
  terminal state, etc.): killing the BEAM task alone leaves the tmux-hosted
  Claude running, so without this the agent keeps editing the slot after it's
  been "replaced" — stacking concurrent writers on one non-isolated checkout.
  """
  @spec kill_by_session_id(String.t() | nil) :: :ok
  def kill_by_session_id(session_id) when is_binary(session_id) and session_id != "" do
    name = session_name(session_id)
    kill_session(name)
    cleanup_prompt_files(session_id)
    :ok
  end

  def kill_by_session_id(_), do: :ok

  @doc "True if the tmux session still exists."
  @spec alive?(session_handle() | String.t()) :: boolean()
  def alive?(%{session_name: session_name}), do: alive?(session_name)

  def alive?(session_name) when is_binary(session_name) do
    match?({_, 0}, tmux(["has-session", "-t", session_name]))
  end

  @doc """
  Locate the session's JSONL event file by its globally unique `<session_id>.jsonl`
  filename under the Claude projects base path.

  Deliberately does NOT compute Claude Code's escaped project directory — that
  escaping rule is version-dependent and broader than `/`→`-`. Returns
  `{:error, :not_found}` until Claude writes the file (it appears on the first
  turn); callers poll.
  """
  @spec session_jsonl_path(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def session_jsonl_path(session_id) when is_binary(session_id) do
    base = Path.expand(Config.claude_tmux_jsonl_base_path())

    case Path.wildcard(Path.join([base, "*", "#{session_id}.jsonl"])) do
      [path | _] -> {:ok, path}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Poll `session_jsonl_path/1` until the JSONL file appears or the timeout elapses.
  """
  @spec await_jsonl(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :not_found}
  def await_jsonl(session_id, opts \\ []) do
    poll_ms = Keyword.get(opts, :poll_interval_ms, Config.claude_tmux_ready_poll_interval_ms())
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.claude_tmux_ready_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_jsonl(session_id, poll_ms, deadline)
  end

  @doc """
  Kill leftover Symphony tmux sessions and remove their prompt temp files.

  Called at application startup: a freshly-booted BEAM owns no agent runs, so any
  tmux session matching the Symphony prefix is a leak from a previous run that
  crashed before `stop_session/1` ran (the tmux session outlives the BEAM). This
  assumes a single Symphony orchestrator per host, which is the deployment model.

  Returns the list of session names reaped. Safe to call when no tmux server is
  running (returns `[]`).
  """
  @spec reap_orphan_sessions(String.t() | nil) :: [String.t()]
  def reap_orphan_sessions(prefix \\ nil), do: reap_orphan_sessions_except([], prefix: prefix)

  @doc """
  Reap Symphony tmux sessions whose session_id is NOT in `keep_session_ids`.

  The orchestrator calls this every poll with the session_ids of its currently
  running workers, so a session leaked mid-run (a worker killed without its
  `stop_session/1` cleanup firing) gets cleaned up within one poll instead of
  surviving until the next BEAM restart. Mirrors `reap_stale_pool_locks` for
  slot locks. `keep_session_ids` may be a list or MapSet.

  Options:

    * `:prefix` — session-name prefix (defaults to the configured one).
    * `:min_age_seconds` — only reap sessions at least this old (default `0`,
      reap regardless of age — what the startup reaper wants). The periodic
      caller passes a grace window so a just-launched worker, whose tmux session
      exists before its session_id has propagated into the running map, is not
      mistaken for a leak and killed.

  Returns the list of session names reaped. Safe when no tmux server is running.
  """
  @spec reap_orphan_sessions_except(Enumerable.t(), keyword()) :: [String.t()]
  def reap_orphan_sessions_except(keep_session_ids, opts \\ []) do
    prefix = opts[:prefix] || Config.claude_tmux_session_prefix()
    min_age = opts[:min_age_seconds] || 0
    keep = MapSet.new(keep_session_ids)
    now = System.os_time(:second)

    case tmux(["list-sessions", "-F", "#S\t\#{session_created}"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_session_line/1)
        |> Enum.filter(fn {name, _created} -> String.starts_with?(name, prefix <> "-") end)
        |> Enum.reject(fn {name, _} -> MapSet.member?(keep, session_id_from_name(name, prefix)) end)
        |> Enum.filter(fn {_name, created} -> old_enough?(created, now, min_age) end)
        |> Enum.map(fn {name, _created} ->
          kill_session(name)
          cleanup_prompt_files(session_id_from_name(name, prefix))
          name
        end)

      _ ->
        # No tmux server (nothing to reap) or tmux not installed.
        []
    end
  end

  # Splits "name\t<epoch>" from tmux; created is nil when the field is absent.
  defp parse_session_line(line) do
    case String.split(line, "\t", parts: 2) do
      [name, created] -> {name, parse_epoch(created)}
      [name] -> {name, nil}
    end
  end

  defp parse_epoch(str) do
    case Integer.parse(String.trim(str)) do
      {epoch, _} -> epoch
      :error -> nil
    end
  end

  # min_age 0 → reap regardless of age (startup). Otherwise require a known
  # creation time older than the grace window; unknown age → don't reap (a
  # live worker is never worth the risk).
  defp old_enough?(_created, _now, min_age) when min_age <= 0, do: true
  defp old_enough?(nil, _now, _min_age), do: false
  defp old_enough?(created, now, min_age), do: now - created >= min_age

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp session_id_from_name(name, prefix), do: String.replace_prefix(name, prefix <> "-", "")

  defp settle_paste do
    Process.sleep(Config.claude_tmux_paste_settle_ms())
    :ok
  end

  # Clear the input, load the prompt buffer and paste it, then confirm the prompt
  # is visible in the pane. Clearing first makes a retry idempotent: a paste that
  # rendered slower than the settle delay won't be duplicated on the next attempt.
  # A single Ctrl-U only clears one visual line, so we repeat it to wipe a
  # multi-line input (e.g. an accumulated "[Pasted text]" block) entirely.
  defp paste_until_visible(session_name, _prompt_file, _prompt, 0) do
    # The error path kills this session, destroying the evidence — log the pane
    # tail first so a paste failure is diagnosable post-mortem.
    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} ->
        tail = output |> String.split("\n") |> Enum.take(-15) |> Enum.join("\n")
        Logger.warning("paste_not_visible for #{session_name}; pane tail:\n#{tail}")

      _ ->
        :ok
    end

    {:error, :paste_not_visible}
  end

  defp paste_until_visible(session_name, prompt_file, prompt, attempts_left) do
    with {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "-N", "25", "C-u"]),
         {_, 0} <- tmux(["load-buffer", prompt_file]),
         {_, 0} <- tmux(["paste-buffer", "-p", "-t", pane(session_name)]),
         :ok <- settle_paste() do
      if paste_visible?(session_name, prompt) do
        :ok
      else
        # On a loaded machine (several workers compiling at once) the TUI can
        # lag well past one settle window — observed as :paste_not_visible
        # storms during dispatch churn. Back off progressively before the next
        # attempt instead of burning all retries inside a few seconds.
        Process.sleep((@paste_attempts - attempts_left + 1) * 1_000)
        paste_until_visible(session_name, prompt_file, prompt, attempts_left - 1)
      end
    else
      {output, code} -> {:error, {:tmux_paste_failed, code, String.trim(output)}}
    end
  end

  # Confirm the WHOLE paste reached the input box — not just its tail. Only the
  # input region of the pane is inspected (from the last "❯" input marker down),
  # so a prompt already submitted and sitting in the transcript above cannot
  # produce a false positive.
  #
  # Two signals, either of which proves the paste landed intact:
  #   * a "[Pasted text #N +L lines]" placeholder whose L equals the prompt's
  #     newline count — the TUI collapses a multi-line bracketed paste into this
  #     placeholder, and L is the number of newlines it actually received, so a
  #     paste that lost its head shows a smaller L (or no placeholder at all);
  #   * the prompt's PREFIX and SUFFIX both visible — a prompt of only a few
  #     lines renders literally, and requiring both ends rejects a tail-only
  #     delivery.
  # Accepting the suffix alone (or any "[Pasted text" at all) is what let
  # truncated prompts through on 2026-09-09: three GEA-7669 workers received the
  # last ~390 characters of a 20 KB Implement prompt and reported "no task".
  # Whitespace is stripped before matching because the TUI reflows and wraps
  # long lines at the pane width, mid-word.
  @input_tail_lines 12
  @placeholder_re ~r/\[Pasted text #\d+ \+(\d+) lines?\]/

  defp paste_visible?(session_name, prompt) do
    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} -> paste_landed?(output, prompt)
      _ -> false
    end
  end

  @doc false
  # Pure check over a pane capture; public so the rule is unit-testable.
  @spec paste_landed?(String.t(), String.t()) :: boolean()
  def paste_landed?(pane_output, prompt) when is_binary(pane_output) and is_binary(prompt) do
    region = input_region(pane_output)
    newlines = length(String.split(prompt, "\n")) - 1

    placeholder_ok? =
      @placeholder_re
      |> Regex.scan(region)
      |> Enum.any?(fn [_, count] -> String.to_integer(count) == newlines end)

    {prefix, suffix} = prompt_needles(prompt)
    compact = compact(region)

    literal_ok? =
      prefix != "" and String.contains?(compact, prefix) and
        (suffix == "" or String.contains?(compact, suffix))

    placeholder_ok? or literal_ok?
  end

  # The input box: from the last line carrying the "❯" input marker to the end
  # of the pane (trailing padding dropped). Submitted prompts render in the
  # transcript with ">" instead, so they fall outside this window even when a
  # short reply leaves them near the bottom. Falls back to the last
  # @input_tail_lines lines when no marker is visible.
  defp input_region(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.reverse()

    marker_index =
      lines
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {line, i}, acc ->
        if String.starts_with?(String.trim_leading(line), "❯"), do: i, else: acc
      end)

    region =
      case marker_index do
        nil -> Enum.take(lines, -@input_tail_lines)
        i -> Enum.drop(lines, i)
      end

    region |> Enum.join(" ") |> squish()
  end

  # A distinctive prefix and suffix of the prompt, whitespace stripped, ~24
  # chars each. Both must be present for a literal (uncollapsed) render.
  defp prompt_needles(prompt) do
    compacted = compact(prompt)
    prefix = String.slice(compacted, 0, 24)
    suffix = if String.length(compacted) > 24, do: String.slice(compacted, -24, 24), else: ""
    {prefix, suffix}
  end

  defp compact(text), do: String.replace(text, ~r/\s+/, "")

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp session_name(session_id), do: "#{Config.claude_tmux_session_prefix()}-#{session_id}"

  # Claude Code runs in the session's only window. Target the session's
  # active window (`session:`) rather than a hardcoded index — the first
  # window is 0 only when the user's tmux config doesn't set `base-index`
  # (a common customization is `base-index 1`, which made `session:0`
  # fail with "can't find window: 0").
  defp pane(session_name), do: "#{session_name}:"

  # Env vars the agent's prompt promises it has. A tmux session inherits the
  # tmux SERVER's environment, not this BEAM's — so anything Symphony was
  # launched with (sourced .env) silently vanishes from agent sessions unless
  # passed explicitly. A tester that was promised $LINEAR_API_KEY_AUTOMATION
  # and didn't have it went hunting through the macOS keychain and 1Password
  # for it — deliver on the promise instead. SYMPHONY_SCRIPTS likewise: the
  # tester prompt says `${SYMPHONY_SCRIPTS}linear-upload-image.sh`; without
  # the var, testers hand-roll unverified Linear uploads and post dangling
  # asset URLs (broken screenshots, observed GEA-4478).
  @session_env_passthrough ~w(LINEAR_API_KEY LINEAR_API_KEY_AUTOMATION)

  defp session_env_args do
    passthrough =
      Enum.flat_map(@session_env_passthrough, fn var ->
        case System.get_env(var) do
          nil -> []
          value -> ["-e", "#{var}=#{value}"]
        end
      end)

    # SYMPHONY_SCRIPTS is computed, not inherited: the beam env doesn't carry
    # it (the hook runner computes it the same way for hook processes).
    passthrough ++ ["-e", "SYMPHONY_SCRIPTS=#{SymphonyElixir.Workspace.scripts_path("")}/"]
  end

  defp new_tmux_session(session_name, workspace) do
    args =
      [
        "new-session",
        "-d",
        "-s",
        session_name,
        "-x",
        Integer.to_string(Config.claude_tmux_width()),
        "-y",
        Integer.to_string(Config.claude_tmux_height()),
        "-c",
        workspace
      ] ++ session_env_args()

    case tmux(args) do
      {_, 0} ->
        # Let tmux settle before sending keystrokes.
        Process.sleep(Config.claude_tmux_startup_delay_ms())
        :ok

      {output, code} ->
        {:error, {:tmux_new_session_failed, code, String.trim(output)}}
    end
  end

  defp launch_claude(session_name, session_id, opts) do
    # `unset CLAUDECODE` so the nested CLI doesn't think it's running inside
    # another Claude Code session. Note: `--dangerously-skip-permissions` does
    # NOT suppress the per-directory "Do you trust this folder?" dialog on a
    # fresh workspace clone — `wait_for_ready` auto-answers it.
    sysprompt_ref = write_system_prompt(session_id, Keyword.get(opts, :append_system_prompt))

    command =
      "unset CLAUDECODE && #{claude_invocation(session_id, opts, sysprompt_ref)}"

    with {_, 0} <- tmux(["send-keys", "-t", pane(session_name), command]),
         {_, 0} <- tmux(["send-keys", "-t", pane(session_name), "Enter"]) do
      :ok
    else
      {output, code} -> {:error, {:tmux_launch_failed, code, String.trim(output)}}
    end
  end

  # Write the caller's system prompt to a temp file and return a shell fragment
  # that expands it as a single argument via `"$(cat ...)"`. This keeps the
  # launch command on ONE line even when the prompt spans many lines — a literal
  # newline in the command string would be submitted as Enter and break the
  # invocation. Returns "" when no system prompt was requested. The file matches
  # this session's prompt-file glob, so existing cleanup removes it on stop/reap.
  defp write_system_prompt(_session_id, nil), do: ""
  defp write_system_prompt(_session_id, ""), do: ""

  defp write_system_prompt(session_id, prompt) when is_binary(prompt) do
    path = sysprompt_file_path(session_id)
    File.write!(path, prompt)
    "--append-system-prompt \"$(cat '#{path}')\""
  end

  # `tools` defaults to the worker toolset; pass `tools: ""` for a no-tools
  # reasoning session. The value is single-quoted so an empty string emits
  # `--tools ''` rather than swallowing the next flag.
  defp claude_invocation(session_id, opts, sysprompt_ref) do
    tools = Keyword.get(opts, :tools, @agent_tools)

    base = [
      Config.claude_command(),
      "--session-id",
      session_id,
      "--tools",
      single_quote(tools),
      "--mcp-config",
      single_quote(@mcp_config_json),
      "--strict-mcp-config"
    ]

    model = Keyword.get(opts, :model) || Config.claude_model()

    base
    |> maybe_append_fragment(sysprompt_ref)
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
    |> maybe_add_option(model, "--model")
    |> Enum.join(" ")
  end

  defp maybe_append_fragment(args, ""), do: args
  defp maybe_append_fragment(args, fragment), do: args ++ [fragment]

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _false, _flag), do: args

  defp maybe_add_option(args, nil, _opt), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  # The mcp-config JSON contains characters the shell would mangle; quote it.
  defp single_quote(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"

  defp wait_for_ready(session_name, opts) do
    poll_ms = Keyword.get(opts, :ready_poll_interval_ms, Config.claude_tmux_ready_poll_interval_ms())
    timeout_ms = Keyword.get(opts, :ready_timeout_ms, Config.claude_tmux_ready_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(session_name, poll_ms, deadline)
  end

  defp do_wait_for_ready(session_name, poll_ms, deadline) do
    cond do
      not alive?(session_name) ->
        {:error, :session_died_during_startup}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :ready_timeout}

      true ->
        case pane_state(session_name) do
          :ready ->
            :ok

          :trust ->
            # Accept the "Do you trust this folder?" dialog — the workspace is
            # always our own clone. Which option is preselected has changed:
            # older builds put "1. Yes" under the cursor, Claude Code 2.1.26x
            # puts "No, exit" first and selected, so a bare Enter exits the CLI
            # and leaves a shell in the pane (the next paste then runs as shell
            # commands). Read where the cursor is and only confirm on "Yes".
            answer_trust_dialog(session_name)
            Process.sleep(poll_ms)
            do_wait_for_ready(session_name, poll_ms, deadline)

          :pending ->
            Process.sleep(poll_ms)
            do_wait_for_ready(session_name, poll_ms, deadline)
        end
    end
  end

  # Classify the current screen from a pane capture:
  #   :trust   — the per-directory trust dialog is up (auto-answer it)
  #   :ready   — the main input is live (the footer token counter is present,
  #              which no modal dialog shows)
  #   :pending — still starting up / some other transient screen
  # An unknown modal stays :pending and we time out loudly rather than paste into
  # the wrong context.
  defp pane_state(session_name) do
    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} ->
        cond do
          trust_dialog?(output) -> :trust
          input_ready?(output) -> :ready
          true -> :pending
        end

      _ ->
        :pending
    end
  end

  defp trust_dialog?(output) do
    String.contains?(output, "trust this folder") or
      String.contains?(output, "trust the files")
  end

  defp answer_trust_dialog(session_name) do
    case tmux(["capture-pane", "-t", pane(session_name), "-p"]) do
      {output, 0} ->
        case trust_cursor(output) do
          :yes -> tmux(["send-keys", "-t", pane(session_name), "Enter"])
          # On "No" (or an option we don't recognise) step the cursor and let
          # the next poll re-read it; a two-option menu reaches "Yes" in one
          # step, and an unexpected menu times out loudly instead of exiting.
          _ -> tmux(["send-keys", "-t", pane(session_name), "Down"])
        end

      _ ->
        :ok
    end
  end

  @doc false
  # Which trust-dialog option the "❯" cursor sits on. Public for unit tests.
  @spec trust_cursor(String.t()) :: :yes | :no | :unknown
  def trust_cursor(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(:unknown, fn line ->
      trimmed = String.trim_leading(line)

      cond do
        not String.starts_with?(trimmed, "❯") -> nil
        Regex.match?(~r/^❯\s*(\d+\.\s*)?Yes\b/, trimmed) -> :yes
        Regex.match?(~r/^❯\s*(\d+\.\s*)?No\b/, trimmed) -> :no
        true -> nil
      end
    end)
  end

  # "Ready for a prompt" = the "❯" input marker plus a footer line that only
  # the live main screen shows — modal dialogs (trust, onboarding, the bypass
  # acceptance warning) render neither. Older Claude Code footers show a
  # "<n> tokens" counter; newer ones (v2.1.x) dropped it but always show the
  # permission-mode hint "(shift+tab to cycle)". Accept either, so readiness
  # detection survives CLI UI changes. ("❯" alone is NOT sufficient — modal
  # selection menus use it as their cursor.)
  defp input_ready?(output) do
    String.contains?(output, "❯") and
      (Regex.match?(~r/\d+\s+tokens/, output) or
         String.contains?(output, "shift+tab to cycle"))
  end

  defp do_await_jsonl(session_id, poll_ms, deadline) do
    case session_jsonl_path(session_id) do
      {:ok, path} ->
        {:ok, path}

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :not_found}
        else
          Process.sleep(poll_ms)
          do_await_jsonl(session_id, poll_ms, deadline)
        end
    end
  end

  defp kill_session(session_name) do
    tmux(["kill-session", "-t", session_name])
    :ok
  end

  defp prompt_file_path(session_id, turn) do
    Path.join(System.tmp_dir!(), "symphony-#{session_id}-#{turn}.txt")
  end

  defp sysprompt_file_path(session_id) do
    Path.join(System.tmp_dir!(), "symphony-#{session_id}-sysprompt.txt")
  end

  defp cleanup_prompt_files(session_id) do
    Path.join(System.tmp_dir!(), "symphony-#{session_id}-*.txt")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp ensure_tmux do
    if System.find_executable("tmux"), do: :ok, else: {:error, :tmux_not_found}
  end

  defp tmux(args) do
    System.cmd("tmux", args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {Exception.message(e), 1}
  end

  # Same workspace guardrails as SymphonyElixir.Claude.CLI: only run inside the
  # configured workspace root, the pool-slot root, or a local-dev pool slot.
  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    pool_root = Path.expand("~/Documents/Gearflow")

    cond do
      !File.dir?(expanded) -> {:error, {:invalid_workspace_cwd, :not_a_directory}}
      String.starts_with?(expanded, root) -> :ok
      String.starts_with?(expanded, pool_root) -> :ok
      SymphonyElixir.Workspace.local_dev_slot?(expanded) -> :ok
      true -> {:error, {:invalid_workspace_cwd, :outside_root}}
    end
  end
end
