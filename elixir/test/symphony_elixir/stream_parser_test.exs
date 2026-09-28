defmodule SymphonyElixir.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamParser

  defp assistant_text_event(text) do
    %{"message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    |> Map.put(:event_type, :assistant)
  end

  defp assistant_tool_event(tool_name, input) do
    %{"message" => %{"content" => [%{"type" => "tool_use", "name" => tool_name, "input" => input}]}}
    |> Map.put(:event_type, :assistant)
  end

  defp tool_result_event(stdout, content \\ nil) do
    event = %{
      "tool_use_result" => %{"stdout" => stdout},
      "message" => %{
        "content" =>
          if content do
            [%{"type" => "tool_result", "content" => content}]
          else
            []
          end
      }
    }

    Map.put(event, :event_type, :tool_result)
  end

  describe "extract_session_id/1" do
    test "matches snake_case session_id (stream-json)" do
      assert StreamParser.extract_session_id(%{"session_id" => "snake"}) == "snake"
    end

    test "matches camelCase sessionId (interactive JSONL)" do
      assert StreamParser.extract_session_id(%{"sessionId" => "camel"}) == "camel"
    end

    test "returns nil when absent" do
      assert StreamParser.extract_session_id(%{"type" => "assistant"}) == nil
    end
  end

  describe "extract_phase/1" do
    test "extracts explicit phase header from assistant text" do
      event = assistant_text_event("### Phase 1: Investigate\n\nLet me look at the code...")
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Investigate from Read tool" do
      event = assistant_tool_event("Read", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Investigate from Grep tool" do
      event = assistant_tool_event("Grep", %{"pattern" => "defmodule"})
      assert StreamParser.extract_phase(event) == "Investigate"
    end

    test "infers Implement from Edit tool" do
      event = assistant_tool_event("Edit", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Implement"
    end

    test "infers Implement from Write tool" do
      event = assistant_tool_event("Write", %{"file_path" => "/some/file.ex"})
      assert StreamParser.extract_phase(event) == "Implement"
    end

    test "infers Test from mix test command" do
      event = assistant_tool_event("Bash", %{"command" => "direnv exec . mix test"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Test from mix check command" do
      event = assistant_tool_event("Bash", %{"command" => "direnv exec . mix check"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Test from Playwright MCP tool" do
      event = assistant_tool_event("mcp__playwright__browser_navigate", %{"url" => "http://localhost:3005"})
      assert StreamParser.extract_phase(event) == "Test"
    end

    test "infers Ship from gh pr create command" do
      event = assistant_tool_event("Bash", %{"command" => "gh pr create --title 'Fix' --body 'Done'"})
      assert StreamParser.extract_phase(event) == "Ship"
    end

    test "infers Ship from git push command" do
      event = assistant_tool_event("Bash", %{"command" => "git push -u origin gea-2174"})
      assert StreamParser.extract_phase(event) == "Ship"
    end

    test "infers Share Evidence from a bin/linear comment, not from a curl health check" do
      post = ~s(LINEAR="/data/workspace/local-dev/gf_harness_surfaces/bin/linear"\n"$LINEAR" comment GEA-1 --body-file /tmp/r.md)
      assert StreamParser.extract_phase(assistant_tool_event("Bash", %{"command" => post})) == "Share Evidence"

      probe = ~s(curl -sf "http://127.0.0.1:$PHOENIX_PORT/" >/dev/null && echo "backend up")
      assert StreamParser.extract_phase(assistant_tool_event("Bash", %{"command" => probe})) == nil
    end

    test "returns nil for non-assistant events" do
      event = %{"message" => %{"content" => []}} |> Map.put(:event_type, :tool_result)
      assert StreamParser.extract_phase(event) == nil
    end

    test "returns nil when no phase can be inferred" do
      event = assistant_tool_event("Bash", %{"command" => "ls -la"})
      assert StreamParser.extract_phase(event) == nil
    end
  end

  describe "extract_pr_url/1" do
    test "extracts PR URL from assistant text" do
      event = assistant_text_event("PR created: https://github.com/GearFlowDev/gf_procurement/pull/801")
      assert StreamParser.extract_pr_url(event) == "https://github.com/GearFlowDev/gf_procurement/pull/801"
    end

    test "extracts PR URL from tool_result stdout" do
      event = tool_result_event("https://github.com/org/repo/pull/42\n")
      assert StreamParser.extract_pr_url(event) == "https://github.com/org/repo/pull/42"
    end

    test "extracts PR URL from tool_result content" do
      event = tool_result_event("", "https://github.com/org/repo/pull/99")
      assert StreamParser.extract_pr_url(event) == "https://github.com/org/repo/pull/99"
    end

    test "returns nil for non-matching text" do
      event = assistant_text_event("No PR here, just working on code.")
      assert StreamParser.extract_pr_url(event) == nil
    end

    test "returns nil for system events" do
      event = %{"content" => "https://github.com/org/repo/pull/1"} |> Map.put(:event_type, :system)
      assert StreamParser.extract_pr_url(event) == nil
    end
  end

  describe "extract_needs_help/1" do
    test "extracts help message from assistant text" do
      event = assistant_text_event("SYMPHONY_NEEDS_HELP: I cannot find the database schema for this table")
      assert StreamParser.extract_needs_help(event) == "I cannot find the database schema for this table"
    end

    test "trims whitespace from help message" do
      event = assistant_text_event("SYMPHONY_NEEDS_HELP:   lots of spaces   ")
      assert StreamParser.extract_needs_help(event) == "lots of spaces"
    end

    test "truncates message at 500 characters" do
      long_message = String.duplicate("a", 600)
      event = assistant_text_event("SYMPHONY_NEEDS_HELP: #{long_message}")
      result = StreamParser.extract_needs_help(event)
      assert String.length(result) == 500
    end

    test "returns nil when marker is absent" do
      event = assistant_text_event("Just working on the code, no problems here.")
      assert StreamParser.extract_needs_help(event) == nil
    end

    test "returns nil for non-assistant events" do
      event = %{"content" => "SYMPHONY_NEEDS_HELP: stuck"} |> Map.put(:event_type, :system)
      assert StreamParser.extract_needs_help(event) == nil
    end

    test "extracts help message from tool result stdout" do
      event = tool_result_event("SYMPHONY_NEEDS_HELP: CI is broken and I cannot fix it")
      assert StreamParser.extract_needs_help(event) == "CI is broken and I cannot fix it"
    end

    test "returns nil for tool result without marker" do
      event = tool_result_event("All tests passed")
      assert StreamParser.extract_needs_help(event) == nil
    end
  end
end
