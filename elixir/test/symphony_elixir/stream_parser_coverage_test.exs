defmodule SymphonyElixir.Claude.StreamParserCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamParser

  defp assistant(content), do: %{"message" => %{"content" => content}, event_type: :assistant}
  defp text(text), do: %{"type" => "text", "text" => text}
  defp tool(name, input), do: %{"type" => "tool_use", "name" => name, "input" => input}

  describe "parse_line/1" do
    test "categorizes every known event type" do
      cases = [
        {~s({"type":"system","subtype":"init","session_id":"s1"}), :session_started},
        {~s({"type":"system","subtype":"compact"}), :system},
        {~s({"type":"assistant"}), :assistant},
        {~s({"type":"tool"}), :tool_use},
        {~s({"type":"user"}), :tool_result},
        {~s({"type":"result"}), :result},
        {~s({"type":"rate_limit_event"}), :rate_limit},
        {~s({"type":"mystery"}), :unknown},
        {~s({}), :unknown}
      ]

      for {line, expected} <- cases do
        assert {:ok, %{event_type: ^expected}} = StreamParser.parse_line(line)
      end
    end

    test "keeps the original payload keys" do
      assert {:ok, %{"session_id" => "s1", "type" => "system"}} =
               StreamParser.parse_line(~s({"type":"system","subtype":"init","session_id":"s1"}))
    end

    test "rejects JSON that is not an object" do
      assert StreamParser.parse_line("[1,2]") == {:error, {:not_a_map, "[1,2]"}}
      assert StreamParser.parse_line("42") == {:error, {:not_a_map, "42"}}
    end

    test "rejects invalid JSON" do
      assert {:error, {:json_parse_error, %Jason.DecodeError{}, "{nope"}} = StreamParser.parse_line("{nope")
    end
  end

  describe "extract_session_id/1 atom keys" do
    test "reads atom session_id and sessionId" do
      assert StreamParser.extract_session_id(%{session_id: "a"}) == "a"
      assert StreamParser.extract_session_id(%{sessionId: "b"}) == "b"
    end

    test "ignores a non-binary id" do
      assert StreamParser.extract_session_id(%{"session_id" => 12}) == nil
    end
  end

  describe "extract_usage/1" do
    test "reads top-level string-keyed usage and folds cache tokens into input" do
      event = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cache_creation_input_tokens" => 100,
          "cache_read_input_tokens" => 1000
        }
      }

      assert StreamParser.extract_usage(event) == %{input_tokens: 1110, output_tokens: 5, total_tokens: 1115}
    end

    test "prefers an explicit total" do
      event = %{usage: %{input_tokens: 3, output_tokens: 4, total_tokens: 99}}
      assert StreamParser.extract_usage(event) == %{input_tokens: 3, output_tokens: 4, total_tokens: 99}
    end

    test "reads usage nested in the message (string and atom keys)" do
      assert StreamParser.extract_usage(%{"message" => %{"usage" => %{"output_tokens" => 7}}}) ==
               %{input_tokens: 0, output_tokens: 7, total_tokens: 7}

      assert StreamParser.extract_usage(%{message: %{usage: %{cache_read_input_tokens: 2}}}) ==
               %{input_tokens: 2, output_tokens: 0, total_tokens: 2}
    end

    test "returns nil when no usable counters are present" do
      assert StreamParser.extract_usage(%{}) == nil
      assert StreamParser.extract_usage(%{"message" => "not a map"}) == nil
      assert StreamParser.extract_usage(%{"usage" => "bogus"}) == nil
      assert StreamParser.extract_usage(%{"usage" => %{"input_tokens" => -1, "output_tokens" => "5"}}) == nil
    end
  end

  describe "extract_phase/1 tool inference" do
    test "returns the header even when tools are present, truncated to 30 chars" do
      event = assistant([text("## Phase: " <> String.duplicate("x", 40)), tool("Edit", %{})])
      assert StreamParser.extract_phase(event) == String.duplicate("x", 30)
    end

    test "text without a header and no tools yields nil" do
      assert StreamParser.extract_phase(assistant([text("hello")])) == nil
      assert StreamParser.extract_phase(%{event_type: :assistant}) == nil
    end

    test "Bash commands map to phases" do
      assert StreamParser.extract_phase(assistant([tool("Bash", %{command: "npm run test"})])) == "Test"
      assert StreamParser.extract_phase(assistant([tool("Bash", %{"command" => "npx playwright test"})])) == "Test"
      assert StreamParser.extract_phase(assistant([tool("Bash", %{"command" => "curl https://x"})])) == "Share Evidence"
    end

    test "Bash with a non-map input or no input infers nothing" do
      assert StreamParser.extract_phase(assistant([tool("Bash", "raw")])) == nil
      assert StreamParser.extract_phase(assistant([%{"type" => "tool_use", "name" => "Bash"}])) == nil
    end

    test "a tool_use without input still infers from the name" do
      assert StreamParser.extract_phase(assistant([%{"type" => "tool_use", "name" => "Glob"}])) == "Investigate"
    end

    test "plugin playwright and MultiEdit" do
      assert StreamParser.extract_phase(assistant([tool("mcp__plugin_playwright_x", %{})])) == "Test"
      assert StreamParser.extract_phase(assistant([tool("MultiEdit", %{})])) == "Implement"
    end

    test "Agent is Ship only when the prompt or description mentions a PR" do
      assert StreamParser.extract_phase(assistant([tool("Agent", %{"prompt" => "Open the PR"})])) == "Ship"
      assert StreamParser.extract_phase(assistant([tool("Agent", %{description: "a Pull Request"})])) == "Ship"
      assert StreamParser.extract_phase(assistant([tool("Agent", %{"prompt" => "look around"})])) == nil
      assert StreamParser.extract_phase(assistant([tool("Agent", "not a map")])) == nil
    end

    test "unknown tools are skipped and the first inferable one wins" do
      event = assistant([tool("TodoWrite", %{}), tool("Read", %{})])
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "reads atom-keyed message content for text" do
      event = %{message: %{content: [%{type: "text", text: "### Phase 2: Ship it"}]}, event_type: :assistant}
      assert StreamParser.extract_phase(event) == "Ship it"
    end
  end

  describe "extract_verdict/1" do
    test "reads a bare verdict" do
      assert StreamParser.extract_verdict(assistant([text("SYMPHONY_VERDICT: APPROVE")])) == {"APPROVE", nil, nil}
    end

    test "reads verdict with sha" do
      assert StreamParser.extract_verdict(assistant([text("SYMPHONY_VERDICT: BLOCKED abc1234")])) ==
               {"BLOCKED", "abc1234", nil}
    end

    test "reads verdict with sha and reason" do
      assert StreamParser.extract_verdict(assistant([text("SYMPHONY_VERDICT: REQUEST_CHANGES abcdef12 — tests fail ")])) ==
               {"REQUEST_CHANGES", "abcdef12", "tests fail"}
    end

    test "reads verdict with a reason and no sha" do
      assert StreamParser.extract_verdict(assistant([text("SYMPHONY_VERDICT: BLOCKED - no access")])) ==
               {"BLOCKED", nil, "no access"}
    end

    test "truncates the reason to 500 chars" do
      reason = String.duplicate("r", 700)
      {"APPROVE", nil, got} = StreamParser.extract_verdict(assistant([text("SYMPHONY_VERDICT: APPROVE - " <> reason)]))
      assert String.length(got) == 500
    end

    test "reads a verdict from a tool result" do
      event = %{"tool_use_result" => %{"stdout" => "SYMPHONY_VERDICT: APPROVE"}, event_type: :tool_result}
      assert StreamParser.extract_verdict(event) == {"APPROVE", nil, nil}
    end

    test "returns nil when absent, empty or for other events" do
      assert StreamParser.extract_verdict(assistant([text("all good")])) == nil
      assert StreamParser.extract_verdict(assistant([])) == nil
      assert StreamParser.extract_verdict(%{event_type: :result}) == nil
    end
  end

  describe "extract_text/1" do
    test "joins text blocks and drops the rest" do
      event = assistant([text("a"), tool("Read", %{}), %{type: "text", text: "b"}])
      assert StreamParser.extract_text(event) == "a\nb"
    end

    test "returns empty string with no message" do
      assert StreamParser.extract_text(%{}) == ""
    end
  end

  describe "tool result text" do
    test "reads Claude Code list-shaped tool_use_result" do
      event = %{
        "tool_use_result" => [%{"type" => "text", "text" => "SYMPHONY_NEEDS_HELP: stuck"}, %{"type" => "image"}],
        event_type: :tool_result
      }

      assert StreamParser.extract_needs_help(event) == "stuck"
    end

    test "joins stdout and content results" do
      event = %{
        "tool_use_result" => %{stdout: "first"},
        "message" => %{"content" => [%{"type" => "tool_result", "content" => "https://github.com/o/r/pull/3"}]},
        event_type: :tool_result
      }

      assert StreamParser.extract_pr_url(event) == "https://github.com/o/r/pull/3"
    end

    test "ignores non-tool_result content blocks" do
      event = %{
        "message" => %{"content" => [%{"type" => "text", "text" => "https://github.com/o/r/pull/4"}]},
        event_type: :tool_result
      }

      assert StreamParser.extract_pr_url(event) == nil
    end

    test "empty tool result yields nil" do
      assert StreamParser.extract_needs_help(%{"tool_use_result" => 5, event_type: :tool_result}) == nil
      assert StreamParser.extract_pr_url(%{event_type: :tool_result}) == nil
    end
  end

  describe "extract_pr_url/1 result events" do
    test "reads the result text" do
      assert StreamParser.extract_pr_url(%{"result" => "done https://github.com/a/b/pull/12 ok", event_type: :result}) ==
               "https://github.com/a/b/pull/12"
    end

    test "returns nil for non-binary or missing results" do
      assert StreamParser.extract_pr_url(%{"result" => %{"x" => 1}, event_type: :result}) == nil
      assert StreamParser.extract_pr_url(%{event_type: :result}) == nil
    end
  end

  describe "extract_screenshot_urls/1" do
    test "scans tool results for Linear upload URLs" do
      event = %{
        "tool_use_result" => %{"stdout" => ~s(uploaded "https://uploads.linear.app/a/b.png" and https://uploads.linear.app/c)},
        event_type: :tool_result
      }

      assert StreamParser.extract_screenshot_urls(event) == [
               "https://uploads.linear.app/a/b.png",
               "https://uploads.linear.app/c"
             ]
    end

    test "flags a pending Playwright screenshot tool use" do
      event = %{"message" => %{"content" => [tool("mcp__playwright__browser_take_screenshot", %{})]}, event_type: :tool_use}
      assert StreamParser.extract_screenshot_urls(event) == ["screenshot_pending"]
    end

    test "returns empty for other tool uses and events" do
      event = %{"message" => %{"content" => [tool("Read", %{})]}, event_type: :tool_use}
      assert StreamParser.extract_screenshot_urls(event) == []
      assert StreamParser.extract_screenshot_urls(%{event_type: :assistant}) == []
    end
  end
end
