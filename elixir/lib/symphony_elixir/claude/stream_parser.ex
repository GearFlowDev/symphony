defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from Claude Code's stream-json output.
  """

  require Logger

  # Match "SYMPHONY_NEEDS_HELP: description" markers
  @symphony_needs_help_regex ~r/SYMPHONY_NEEDS_HELP:\s*(.+)/

  # Match "SYMPHONY_VERDICT: APPROVE|REQUEST_CHANGES|BLOCKED [<commit-sha>] [— reason]"
  # markers — the tester's machine-readable verdict, optionally tagged with the
  # tested head and a one-line reason (which rides into the next worker's prompt;
  # without it each Implement pass re-guesses what the tester objected to).
  @symphony_verdict_regex ~r/SYMPHONY_VERDICT:[ \t]*(APPROVE|REQUEST_CHANGES|BLOCKED)(?:[ \t]+([0-9a-fA-F]{7,40}))?(?:[ \t]*[—–-][ \t]*([^\n]+))?/u

  @doc """
  Parse a single JSON line from stdout. Returns {:ok, event_map} or {:error, reason}.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, normalize_event(payload)}
      {:ok, _other} -> {:error, {:not_a_map, line}}
      {:error, reason} -> {:error, {:json_parse_error, reason, line}}
    end
  end

  @doc """
  Extract session_id from a parsed event, if present.

  `-p` stream-json events use `session_id`; interactive JSONL events use the
  camelCase `sessionId`. Match both so the same parser works for either source.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(%{session_id: id}) when is_binary(id), do: id
  def extract_session_id(%{"sessionId" => id}) when is_binary(id), do: id
  def extract_session_id(%{sessionId: id}) when is_binary(id), do: id
  def extract_session_id(_event), do: nil

  @doc """
  Extract usage data from a parsed event.
  Returns a map with :input_tokens, :output_tokens, :total_tokens or nil.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    usage =
      Map.get(event, "usage") ||
        Map.get(event, :usage) ||
        nested_message_usage(event)

    normalize_usage(usage)
  end

  defp nested_message_usage(event) do
    msg = Map.get(event, "message") || Map.get(event, :message)
    if is_map(msg), do: Map.get(msg, "usage") || Map.get(msg, :usage)
  end

  defp normalize_usage(%{} = usage) do
    input = integer_field(usage, ["input_tokens", :input_tokens])
    output = integer_field(usage, ["output_tokens", :output_tokens])
    total = integer_field(usage, ["total_tokens", :total_tokens])

    # Claude Code reports cache tokens separately; include them in the input total
    # so token accounting reflects actual API usage.
    cache_creation = integer_field(usage, ["cache_creation_input_tokens", :cache_creation_input_tokens])
    cache_read = integer_field(usage, ["cache_read_input_tokens", :cache_read_input_tokens])
    effective_input = zero_if_nil(input) + zero_if_nil(cache_creation) + zero_if_nil(cache_read)

    if Enum.any?([input, output, total, cache_creation, cache_read]) do
      %{
        input_tokens: effective_input,
        output_tokens: zero_if_nil(output),
        total_tokens: total || effective_input + zero_if_nil(output)
      }
    end
  end

  defp normalize_usage(_), do: nil

  defp zero_if_nil(nil), do: 0
  defp zero_if_nil(value), do: value

  defp normalize_event(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)
    Map.put(payload, :event_type, categorize_type(type, payload))
  end

  # Only the "init" system event signals the actual start of a session.
  defp categorize_type("system", payload) do
    subtype = Map.get(payload, "subtype") || Map.get(payload, :subtype)
    if subtype == "init", do: :session_started, else: :system
  end

  defp categorize_type("assistant", _payload), do: :assistant
  defp categorize_type("tool", _payload), do: :tool_use
  defp categorize_type("user", _payload), do: :tool_result
  defp categorize_type("result", _payload), do: :result
  defp categorize_type("rate_limit_event", _payload), do: :rate_limit
  defp categorize_type(_, _payload), do: :unknown

  # ---------------------------------------------------------------------------
  # Phase inference
  # ---------------------------------------------------------------------------

  @doc """
  Infer the workflow phase from an event.

  For assistant events: checks text for explicit phase headers ("### Phase N: Name"),
  and infers phase from tool_use names/inputs (Read/Grep = Investigate,
  Edit/Write = Implement, mix test/check = Test, gh pr/git push = Ship).

  For tool_result events: checks stdout for PR creation output.

  Returns a short label or nil.
  """
  @spec extract_phase(map()) :: String.t() | nil
  def extract_phase(%{event_type: :assistant} = event) do
    text = extract_text_content(event)

    # Infer phase from markdown headers or tool usage patterns (for dashboard display)
    detect_phase_header(text) ||
      event |> extract_tool_uses() |> infer_phase_from_tools()
  end

  def extract_phase(_event), do: nil

  @doc """
  Extract a SYMPHONY_NEEDS_HELP message from an event.

  Returns the help description (trimmed, max 500 chars) or nil.
  """
  @spec extract_needs_help(map()) :: String.t() | nil
  def extract_needs_help(%{event_type: :assistant} = event) do
    event |> extract_text_content() |> detect_needs_help()
  end

  def extract_needs_help(%{event_type: :tool_result} = event) do
    event |> extract_tool_result_text() |> detect_needs_help()
  end

  def extract_needs_help(_event), do: nil

  @doc """
  Extract a `SYMPHONY_VERDICT` marker from an event.

  Returns `{verdict, commit_sha | nil, reason | nil}` (verdict is "APPROVE" |
  "REQUEST_CHANGES" | "BLOCKED") or nil when no marker is present.
  """
  @spec extract_verdict(map()) :: {String.t(), String.t() | nil, String.t() | nil} | nil
  def extract_verdict(%{event_type: :assistant} = event) do
    event |> extract_text_content() |> detect_verdict()
  end

  def extract_verdict(%{event_type: :tool_result} = event) do
    event |> extract_tool_result_text() |> detect_verdict()
  end

  def extract_verdict(_event), do: nil

  @doc """
  Concatenate the text blocks of an assistant event's message content.

  Returns the joined text (tool-use and other non-text blocks dropped), or an
  empty string when the event carries no text. Used by `Claude.OneShot` to read
  a single-turn reply out of the session JSONL.
  """
  @spec extract_text(map()) :: String.t()
  def extract_text(event), do: extract_text_content(event)

  defp detect_needs_help(""), do: nil
  defp detect_needs_help(text) when not is_binary(text), do: nil

  defp detect_needs_help(text) do
    case Regex.run(@symphony_needs_help_regex, text) do
      [_, message] -> message |> String.trim() |> String.slice(0, 500)
      nil -> nil
    end
  end

  defp detect_verdict(text) when not is_binary(text) or text == "", do: nil

  defp detect_verdict(text) do
    case Regex.run(@symphony_verdict_regex, text) do
      [_, verdict] -> {verdict, nil, nil}
      [_, verdict, sha] -> {verdict, presence(sha), nil}
      [_, verdict, sha, reason] -> {verdict, presence(sha), presence(reason, 500)}
      nil -> nil
    end
  end

  defp presence(value, max \\ nil)
  defp presence("", _max), do: nil

  defp presence(value, max) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: if(max, do: String.slice(value, 0, max), else: value)
  end

  defp extract_text_content(event) do
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      %{type: "text", text: text} -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  # Match "### Phase N: Name" or "## Phase: Name" patterns
  @phase_header_regex ~r/\#{2,3}\s+Phase\s*(?:\d+)?[:\s]+(.+)/i

  defp detect_phase_header(""), do: nil

  defp detect_phase_header(text) do
    case Regex.run(@phase_header_regex, text) do
      [_, phase_name] -> phase_name |> String.trim() |> String.slice(0, 30)
      nil -> nil
    end
  end

  defp extract_tool_uses(event) do
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "tool_use", "name" => name, "input" => input} -> [{name, input}]
      %{"type" => "tool_use", "name" => name} -> [{name, %{}}]
      _ -> []
    end)
  end

  @ship_tools ~w(Agent)
  @test_commands ~w(mix\ test mix\ check npm\ run\ test)
  @investigate_tools ~w(Read Grep Glob WebFetch WebSearch)
  @implement_tools ~w(Edit Write MultiEdit)

  defp infer_phase_from_tools([]), do: nil

  defp infer_phase_from_tools(tool_uses) do
    Enum.find_value(tool_uses, fn {name, input} -> infer_phase_from_tool(name, input) end)
  end

  defp infer_phase_from_tool("Bash", input) do
    command = get_command(input)

    cond do
      # Ship: gh pr create, git push
      command_matches?(command, ["gh pr create", "git push"]) ->
        "Ship"

      # Test: mix test, mix check, playwright
      command_matches?(command, @test_commands) ->
        "Test"

      String.contains?(command, "playwright") ->
        "Test"

      # Bash with curl to Linear API = sharing evidence
      command_matches?(command, ["curl", "linear.app"]) ->
        "Share Evidence"

      true ->
        nil
    end
  end

  defp infer_phase_from_tool(name, input) do
    cond do
      String.starts_with?(name, "mcp__playwright") or
          String.starts_with?(name, "mcp__plugin_playwright") ->
        "Test"

      # Ship: Agent tool (often used for PR creation)
      name in @ship_tools and agent_is_pr?(input) ->
        "Ship"

      # Implement: Edit, Write
      name in @implement_tools ->
        "Implement"

      # Investigate: Read, Grep, Glob, search
      name in @investigate_tools ->
        "Investigate"

      true ->
        nil
    end
  end

  defp get_command(input) when is_map(input) do
    Map.get(input, "command") || Map.get(input, :command) || ""
  end

  defp get_command(_), do: ""

  defp command_matches?(command, patterns) when is_binary(command) do
    Enum.any?(patterns, &String.contains?(command, &1))
  end

  defp agent_is_pr?(input) when is_map(input) do
    prompt = Map.get(input, "prompt") || Map.get(input, :prompt) || ""
    desc = Map.get(input, "description") || Map.get(input, :description) || ""
    combined = prompt <> " " <> desc

    String.contains?(String.downcase(combined), "pr") or
      String.contains?(String.downcase(combined), "pull request")
  end

  defp agent_is_pr?(_), do: false

  # ---------------------------------------------------------------------------
  # PR URL extraction
  # ---------------------------------------------------------------------------

  @doc """
  Extract a GitHub PR URL from any event's text content.

  Checks:
  - Assistant message text (agent mentions the PR URL after creating it)
  - Tool result stdout (output of `gh pr create`)
  - Result event text

  Returns the first match or nil.
  """
  @spec extract_pr_url(map()) :: String.t() | nil
  def extract_pr_url(%{event_type: :assistant} = event) do
    event |> extract_text_content() |> detect_pr_url()
  end

  def extract_pr_url(%{event_type: :tool_result} = event) do
    event |> extract_tool_result_text() |> detect_pr_url()
  end

  def extract_pr_url(%{event_type: :result} = event) do
    result = Map.get(event, "result") || Map.get(event, :result) || ""
    if is_binary(result), do: detect_pr_url(result), else: nil
  end

  def extract_pr_url(_event), do: nil

  defp extract_tool_result_text(event) do
    # tool_use_result may be a map with "stdout" (Codex) or a list of content
    # blocks (Claude Code: [%{"text" => "...", "type" => "text"}]).
    tool_result = Map.get(event, "tool_use_result")
    stdout = extract_stdout(tool_result)

    # Also check message.content[].content for tool_result blocks
    message = Map.get(event, "message") || Map.get(event, :message) || %{}
    content = Map.get(message, "content") || Map.get(message, :content) || []

    result_text =
      content
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "tool_result", "content" => c} when is_binary(c) -> [c]
        _ -> []
      end)
      |> Enum.join("\n")

    case {stdout, result_text} do
      {"", ""} -> ""
      {s, ""} -> s
      {"", r} -> r
      {s, r} -> s <> "\n" <> r
    end
  end

  defp extract_stdout(tool_result) when is_map(tool_result) do
    Map.get(tool_result, "stdout") || Map.get(tool_result, :stdout) || ""
  end

  defp extract_stdout(tool_result) when is_list(tool_result) do
    tool_result
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_stdout(_), do: ""

  # ---------------------------------------------------------------------------
  # Screenshot URL extraction
  # ---------------------------------------------------------------------------

  @linear_asset_url_regex ~r{https://uploads\.linear\.app/[^\s"'<>)]+}

  @doc """
  Extract Linear asset URLs from tool results (screenshot uploads).
  Also detects Playwright screenshot tool uses.
  """
  @spec extract_screenshot_urls(map()) :: [String.t()]
  def extract_screenshot_urls(%{event_type: :tool_result} = event) do
    text = extract_tool_result_text(event)

    @linear_asset_url_regex
    |> Regex.scan(text)
    |> Enum.map(fn [url] -> url end)
  end

  def extract_screenshot_urls(%{event_type: :tool_use} = event) do
    tool_uses = extract_tool_uses(event)

    has_screenshot =
      Enum.any?(tool_uses, fn {name, _input} ->
        String.contains?(name, "browser_take_screenshot")
      end)

    if has_screenshot, do: ["screenshot_pending"], else: []
  end

  def extract_screenshot_urls(_event), do: []

  @pr_url_regex ~r{https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+}

  defp detect_pr_url(""), do: nil

  defp detect_pr_url(text) do
    case Regex.run(@pr_url_regex, text) do
      [url] -> url
      nil -> nil
    end
  end

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        v when is_integer(v) and v >= 0 -> v
        _ -> nil
      end
    end)
  end
end
