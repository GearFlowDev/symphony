defmodule SymphonyElixir.Claude.OneShot do
  @moduledoc """
  Single-turn, no-tools Claude invocations for orchestrator-side reasoning
  (Planner, Grader, Auditor).

  Unlike `SymphonyElixir.Claude.AgentRunner`, which drives a long multi-turn
  agent session, OneShot starts a fresh tmux-hosted Claude session per call,
  sends one prompt, waits for the turn to finish, reads the assistant's reply
  out of the session JSONL, and tears the session down.

  Running through `Claude.TmuxCLI` instead of `claude -p` is the whole point:
  print mode bills against Anthropic's programmatic credit pool, while a
  tmux-hosted interactive session bills against the plan. The session is started
  with `tools: ""` (no tools) and the caller's system prompt appended, so the
  model answers with text only.

  ## API

  `request/3` returns the assistant's text. `request_json/3` parses that text as
  JSON (stripping a surrounding ```json fence), retrying once with a corrective
  nudge if the first reply isn't valid JSON. Both keep the signatures the
  Planner and Grader call with, so callers don't change.

  Options: `:cwd` (workspace the session runs in — should be the issue's slot;
  defaults to the configured workspace root), `:timeout_ms`, `:tools` (defaults
  to `""`). `:session_module` / `:watcher_module` are injectable for tests.
  """

  import Bitwise

  require Logger

  alias SymphonyElixir.Claude.{SessionWatcher, StreamParser, TmuxCLI}
  alias SymphonyElixir.Config

  @default_timeout_ms 180_000

  @type opts :: [
          cwd: Path.t(),
          timeout_ms: pos_integer(),
          tools: String.t()
        ]

  @doc """
  Send a one-shot prompt and return the assistant's text reply.

  The system prompt is delivered via `--append-system-prompt`; `user_prompt` is
  sent as the single turn. Returns `{:error, :empty_reply}` if the turn produced
  no assistant text.
  """
  @spec request(String.t(), String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def request(system_prompt, user_prompt, opts \\ [])
      when is_binary(system_prompt) and is_binary(user_prompt) do
    session_mod = Keyword.get(opts, :session_module, TmuxCLI)
    watcher_mod = Keyword.get(opts, :watcher_module, SessionWatcher)
    workspace = Keyword.get(opts, :cwd) || Config.workspace_root()
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    tools = Keyword.get(opts, :tools, "")
    session_id = uuid4()

    start_opts = [tools: tools, append_system_prompt: system_prompt]
    start_opts = if model = Keyword.get(opts, :model), do: Keyword.put(start_opts, :model, model), else: start_opts

    case session_mod.start_session(workspace, session_id, start_opts) do
      {:ok, session} ->
        try do
          run_turn(session_mod, watcher_mod, session, session_id, user_prompt, timeout_ms)
        after
          session_mod.stop_session(session)
        end

      {:error, reason} ->
        {:error, {:start_session_failed, reason}}
    end
  end

  @doc """
  Like `request/3` but parse the assistant's reply as JSON. Strips a surrounding
  ```json ... ``` fence if present, then `Jason.decode`. Retries once with a
  corrective nudge if the first reply isn't valid JSON.
  """
  @spec request_json(String.t(), String.t(), opts()) :: {:ok, map() | list()} | {:error, term()}
  @json_max_attempts 3

  def request_json(system_prompt, user_prompt, opts \\ []) do
    request_json_attempt(system_prompt, user_prompt, opts, 1)
  end

  # Retry malformed responses: the model sometimes answers with prose, a code
  # fence, or a tool-use preamble (e.g. "Tool use: **Bash** ...") instead of
  # clean JSON. Re-ask up to @json_max_attempts with a firmer reminder before
  # giving up, so one bad turn doesn't block planning/grading.
  defp request_json_attempt(system_prompt, user_prompt, opts, attempt) do
    case request(system_prompt, user_prompt, opts) do
      {:ok, text} ->
        case decode_json(text) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> retry_json_attempt(system_prompt, user_prompt, opts, attempt, err)
        end

      err ->
        err
    end
  end

  defp retry_json_attempt(system_prompt, user_prompt, opts, attempt, err) do
    if attempt < @json_max_attempts do
      Logger.warning("OneShot JSON decode failed (attempt #{attempt}/#{@json_max_attempts}); retrying.")

      retry_user =
        user_prompt <>
          "\n\n[reminder] Reply with ONLY a single JSON object — no prose, no explanation, no tool calls, no code fences."

      request_json_attempt(system_prompt, retry_user, opts, attempt + 1)
    else
      Logger.warning("OneShot JSON decode failed after #{@json_max_attempts} attempts.")
      err
    end
  end

  # Send the single prompt, watch the JSONL for the turn to complete, then read
  # the reply out of it. The watcher reads from offset 0, so the prompt's events
  # are not lost even though it starts after send_prompt.
  defp run_turn(session_mod, watcher_mod, session, session_id, user_prompt, timeout_ms) do
    with :ok <- session_mod.send_prompt(session, user_prompt, 1),
         {:ok, jsonl_path} <- session_mod.await_jsonl(session_id),
         {:ok, watcher} <-
           watcher_mod.start_link(jsonl_path: jsonl_path, on_event: fn _event -> :ok end) do
      try do
        case watcher_mod.wait_for_turn(watcher, timeout_ms) do
          {:ok, _summary} -> read_reply(jsonl_path)
          {:error, reason} -> {:error, {:turn_failed, reason}}
        end
      after
        watcher_mod.stop(watcher)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Return the text of the last main-chain assistant message in the JSONL.
  # Sidechain (subagent) messages and tool-use-only messages are skipped — a
  # no-tools one-shot normally has exactly one assistant message anyway.
  defp read_reply(jsonl_path) do
    case File.read(jsonl_path) do
      {:ok, contents} ->
        text =
          contents
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_event_line/1)
          |> Enum.filter(&assistant_text_event?/1)
          |> List.last()
          |> case do
            nil -> ""
            event -> StreamParser.extract_text(event)
          end

        if String.trim(text) == "", do: {:error, :empty_reply}, else: {:ok, String.trim(text)}

      {:error, reason} ->
        {:error, {:jsonl_read_failed, reason}}
    end
  end

  defp parse_event_line(line) do
    case StreamParser.parse_line(line) do
      {:ok, event} -> [event]
      _ -> []
    end
  end

  defp assistant_text_event?(%{event_type: :assistant} = event) do
    not sidechain?(event) and StreamParser.extract_text(event) != ""
  end

  defp assistant_text_event?(_event), do: false

  defp sidechain?(event) do
    Map.get(event, "isSidechain") == true || Map.get(event, :isSidechain) == true
  end

  defp decode_json(text) do
    trimmed = strip_code_fence(text)

    case Jason.decode(trimmed) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, {:json_decode, text}}
    end
  end

  defp strip_code_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*\n/, "")
    |> String.replace(~r/\n```\s*$/, "")
    |> String.trim()
  end

  # RFC 4122 version-4 UUID. Claude Code's --session-id requires a valid UUID;
  # it is also the JSONL filename TmuxCLI locates the session by.
  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = c |> band(0x0FFF) |> bor(0x4000)
    d = d |> band(0x3FFF) |> bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
