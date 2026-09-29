defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Spawns Claude Code CLI subprocesses and streams events back to the caller.

  Each turn is spawn-run-exit (no persistent connection like Codex app-server).
  Continuations use `claude --resume <session_id>`.
  """

  require Logger
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_log_bytes 1_000

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @doc """
  Run a first-turn Claude Code session with the given prompt.
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, workspace, opts \\ []) do
    args = build_first_turn_args(prompt)
    execute(args, workspace, opts)
  end

  @doc """
  Resume an existing Claude Code session with continuation guidance.
  """
  @spec resume(String.t(), String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, workspace, opts \\ []) do
    args = build_resume_args(session_id, prompt)
    execute(args, workspace, opts)
  end

  defp execute(args, workspace, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.claude_turn_timeout_ms())
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, Config.claude_stall_timeout_ms())

    with :ok <- validate_workspace(workspace) do
      command = Config.claude_command()
      {cmd, cmd_args} = parse_command(command, args)

      # Wrap via /bin/sh so the child runs in a new process group.
      # safe_port_close/1 sends SIGTERM to the entire group via
      # `kill -- -$PID`, preventing orphan Claude processes.
      #
      # We wrap with `script -qfec` to allocate a PTY, forcing Node.js
      # (Claude CLI runtime) into line-buffering mode instead of full buffering.
      wrapper_args = ["-c", build_wrapper_script(cmd, cmd_args)]

      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, @port_line_bytes},
            {:cd, Path.expand(workspace)},
            {:args, wrapper_args},
            {:env, [{~c"CLAUDECODE", false}]}
          ]
        )

      now = System.monotonic_time(:millisecond)
      deadline = now + turn_timeout_ms
      stall_deadline = now + stall_timeout_ms

      try do
        stream_loop(port, deadline, stall_deadline, stall_timeout_ms, on_event, %{
          session_id: nil,
          usage: nil,
          buffer: ""
        })
      catch
        :exit, reason ->
          safe_port_close(port)
          {:error, {:subprocess_exit, reason}}
      end
    end
  end

  defp stream_loop(port, deadline, stall_deadline, stall_timeout_ms, on_event, state) do
    now = System.monotonic_time(:millisecond)
    remaining_ms = max(min(deadline - now, stall_deadline - now), 0)

    cond do
      now >= deadline ->
        safe_port_close(port)
        {:error, :turn_timeout}

      now >= stall_deadline ->
        safe_port_close(port)
        {:error, :stall_timeout}

      true ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            state = handle_line(line, on_event, state)
            new_stall_deadline = System.monotonic_time(:millisecond) + stall_timeout_ms
            stream_loop(port, deadline, new_stall_deadline, stall_timeout_ms, on_event, state)

          {^port, {:data, {:noeol, chunk}}} ->
            new_stall_deadline = System.monotonic_time(:millisecond) + stall_timeout_ms

            stream_loop(port, deadline, new_stall_deadline, stall_timeout_ms, on_event, %{
              state
              | buffer: state.buffer <> chunk
            })

          {^port, {:exit_status, 0}} ->
            {:ok,
             %{
               session_id: state.session_id,
               exit_code: 0,
               usage: state.usage
             }}

          {^port, {:exit_status, code}} ->
            {:error, {:subprocess_exit, code}}
        after
          remaining_ms ->
            safe_port_close(port)

            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :turn_timeout}
            else
              {:error, :stall_timeout}
            end
        end
    end
  end

  defp handle_line(line, on_event, state) do
    # Strip trailing \r from PTY line discipline (script wrapper adds \r\n)
    # and leading control characters that macOS `script` may prepend (^D, ^H, etc.)
    full_line =
      (state.buffer <> line)
      |> String.trim_trailing("\r")
      |> strip_leading_control_chars()

    state = %{state | buffer: ""}

    case StreamParser.parse_line(full_line) do
      {:ok, event} ->
        session_id = StreamParser.extract_session_id(event) || state.session_id
        usage = StreamParser.extract_usage(event) || state.usage
        on_event.(event)
        %{state | session_id: session_id, usage: usage}

      {:error, reason} ->
        Logger.debug("Unparseable stream line: #{inspect(reason)} line=#{String.slice(full_line, 0, @max_log_bytes)}")

        state
    end
  end

  # Restrict to core tools only. MCP plugins (Playwright, Linear, Tidewave)
  # add 50-80 tools that consume hundreds of thousands of context tokens.
  # Agents use curl/bash for Linear API and npx for Playwright instead.
  @agent_tools "Agent,Bash,Edit,Read,Write,Glob,Grep"
  @mcp_config_json "{\"mcpServers\":{}}"

  defp build_first_turn_args(prompt) do
    base = [
      "-p",
      prompt,
      "--verbose",
      "--output-format",
      Config.claude_output_format(),
      "--permission-mode",
      Config.claude_permission_mode(),
      "--tools",
      @agent_tools,
      "--mcp-config",
      @mcp_config_json,
      "--strict-mcp-config"
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
    |> maybe_add_option(Config.claude_model(), "--model")
    |> maybe_add_allowed_tools(Config.claude_allowed_tools())
  end

  defp build_resume_args(session_id, prompt) do
    base = [
      "--resume",
      session_id,
      "-p",
      prompt,
      "--verbose",
      "--output-format",
      Config.claude_output_format(),
      "--permission-mode",
      Config.claude_permission_mode(),
      "--tools",
      @agent_tools,
      "--mcp-config",
      @mcp_config_json,
      "--strict-mcp-config"
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _, _flag), do: args

  defp maybe_add_option(args, nil, _opt), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, []), do: args

  defp maybe_add_allowed_tools(args, tools) when is_list(tools) do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)
  end

  defp parse_command(command, extra_args) do
    parts = String.split(command, ~r/\s+/, trim: true)

    {cmd, cmd_args} =
      case parts do
        [cmd | rest] -> {cmd, rest ++ extra_args}
        [] -> {"claude", extra_args}
      end

    resolved_cmd = System.find_executable(cmd) || cmd
    {resolved_cmd, cmd_args}
  end

  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    pool_root = Path.expand("~/Documents/Gearflow")

    cond do
      !File.dir?(expanded) ->
        {:error, {:invalid_workspace_cwd, :not_a_directory}}

      String.starts_with?(expanded, root) ->
        :ok

      String.starts_with?(expanded, pool_root) ->
        # Allow pool slot directories under the configured pool root
        :ok

      SymphonyElixir.Workspace.local_dev_slot?(expanded) ->
        # Allow local-dev pool slots under $GEARFLOW_WORKSPACE/local-dev
        :ok

      true ->
        {:error, {:invalid_workspace_cwd, :outside_root}}
    end
  end

  defp safe_port_close(port) do
    os_pid =
      try do
        {:os_pid, pid} = Port.info(port, :os_pid)
        pid
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    Port.close(port)

    if is_integer(os_pid) and os_pid > 0 do
      System.cmd("kill", ["--", "-#{os_pid}"], stderr_to_stdout: true)
    end
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp build_wrapper_script(cmd, args) do
    # Shell-escape each argument, then exec the command.
    # exec replaces the shell so the process inherits the shell's PID/PGID,
    # making `kill -- -$PID` reach the entire tree.
    #
    # We wrap with `script` to allocate a PTY. Without this, Node.js
    # (which powers the Claude CLI) fully buffers stdout when writing to a pipe,
    # and stream-json events only appear when the internal buffer fills (~64KB)
    # or the process exits. The PTY tricks Node into line-buffering.
    #
    # macOS: script -q /dev/null <command>
    # Linux: script -qfec <command> /dev/null
    escaped_args =
      Enum.map_join([cmd | args], " ", fn arg ->
        "'" <> String.replace(arg, "'", "'\\''") <> "'"
      end)

    # Wrap with `script` to allocate a PTY, forcing Node.js into line-buffering.
    # Without a PTY, Node.js fully buffers stdout to pipes, and the Erlang port
    # never receives stream-json events until the buffer fills.
    # macOS: script -q /dev/null <command>
    # Linux: script -qfec <command> /dev/null
    case :os.type() do
      {:unix, :darwin} ->
        "exec script -q /dev/null #{escaped_args}"

      _ ->
        "exec script -qfec #{shell_escape(escaped_args)} /dev/null"
    end
  end

  # macOS `script` may prepend control characters (^D=0x04, ^H=0x08, etc.)
  # to the first line of output. Strip any non-printable bytes before the
  # opening `{` so the JSON parser sees clean input.
  defp strip_leading_control_chars(<<c, rest::binary>>) when c < 0x20, do: strip_leading_control_chars(rest)
  defp strip_leading_control_chars(line), do: line

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
