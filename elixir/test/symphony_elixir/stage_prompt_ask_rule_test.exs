defmodule SymphonyElixir.StagePromptAskRuleTest do
  @moduledoc """
  A stage prompt that invites a needs-help exit on a question the grant already
  settles stops a run for nothing (GEA-10513). The ask rule lives in gf_engineering
  `CLAUDE.md`; the prompts point to it and do not restate it. These assertions read
  the prompts this repository ships, because the prompts are the behaviour.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow.StageLoader

  @stages_dir Path.expand("../../workflow/stages", __DIR__)

  defp stage(name), do: File.read!(Path.join(@stages_dir, name))

  # The list between "true blockers" and "Do NOT use this for" is what the agent
  # reads as permission to stop. Split on both headings so the explanation above
  # the list cannot satisfy the refutes below.
  defp true_blocker_list do
    [_, rest] = String.split(stage("_preamble.md"), "Use this ONLY for true blockers:", parts: 2)
    [list, _] = String.split(rest, "Do NOT use this for:", parts: 2)
    list
  end

  test "the preamble points to the ask rule instead of restating it" do
    assert stage("_preamble.md") =~ "`CLAUDE.md` → Who you are and what you may do → Asking"
  end

  test "an unclear requirement is not a true blocker" do
    refute true_blocker_list() =~ ~r/unclear|clarif|ambigu/i
  end

  test "a blocked verdict never covers a product question" do
    assert stage("_preamble.md") =~ "A product question never makes a dispatch `blocked`."
  end

  test "the kickoff plan lists open questions with the default the run takes" do
    kickoff = stage("01-kickoff.md")

    refute kickoff =~ "might need human input"
    assert kickoff =~ "the default you build to"
  end

  test "no stage posts to Linear with curl; every Linear call goes through bin/linear (GEA-10619)" do
    for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) do
      content = File.read!(path)
      name = Path.basename(path)

      refute content =~ "api.linear.app", "#{name} still calls the Linear API with curl"
      refute content =~ "LINEAR_API_KEY_AUTOMATION", "#{name} still names a key the box does not set"
    end

    for name <- ["01-kickoff.md", "03-test.md", "03-human-review.md", "04-simplify.md"] do
      assert stage(name) =~ ~s({{ tools.linear }} comment {{ issue.identifier }} --body-file),
             "#{name} does not post through bin/linear"
    end

    assert stage("_continuation.md") =~ ~s({{ tools.linear }} comments {{ issue.identifier }})
  end

  test "the continuation prompt reaches the agent with the issue's identifier filled in (GEA-10619)" do
    stages = %{"_continuation.md" => stage("_continuation.md")}

    values = %{
      "slot" => %{"directory" => "/data/workspace/local-dev/gf_procurement-slot3", "base_branch" => "main"},
      "tools" => %{
        "pr" => "/data/workspace/local-dev/bin/pr",
        "linear" => "/data/workspace/local-dev/gf_harness_surfaces/bin/linear"
      }
    }

    prompt = StageLoader.assemble_continuation(stages, 2, 20, [], "GEA-7", values)

    assert prompt =~ ~s(/data/workspace/local-dev/gf_harness_surfaces/bin/linear comments GEA-7 --since)
    assert prompt =~ "cd /data/workspace/local-dev/gf_procurement-slot3 && /data/workspace/local-dev/bin/pr push"
    assert prompt =~ "`GEA-7: <row-id> <summary>`"
    refute prompt =~ "{{"
  end

  test "an identifier that is not Linear-shaped never reaches the shell command" do
    stages = %{"_continuation.md" => stage("_continuation.md")}

    for bad <- ["GEA-7; rm -rf /", "GEA-7 $(id)", "gea-7", ""] do
      prompt = StageLoader.assemble_continuation(stages, 2, 20, [], bad)
      assert prompt =~ ~s({{ tools.linear }} comments {{ issue.identifier }} --since)
    end
  end

  test "no stage describes the deleted React app, its frontend server or its ?lv= flags (GEA-10619)" do
    for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) do
      content = File.read!(path)
      name = Path.basename(path)

      refute content =~ "$FRONTEND_PORT", "#{name} still reaches for a frontend server"
      refute content =~ "FRONTEND_PORT}", "#{name} still reaches for a frontend server"
      refute content =~ ~r/\?lv=(on|off)/, "#{name} still walks the deleted ?lv= flags"
      refute content =~ "lv_*", "#{name} still sweeps the deleted lv_* flags"
      refute content =~ "React and LV", "#{name} still walks the React app"
      refute content =~ ~r/already running/i, "#{name} still says the backend is already running"
    end

    assert stage("_preamble.md") =~ "The backend is NOT started for you."
  end

  test "the preamble does not cancel the workspace rules it then cites (GEA-10619)" do
    preamble = stage("_preamble.md")

    refute preamble =~ "managing Linear issue lifecycle"
    assert preamble =~ "These parts do apply to you:** the ask rule"
  end

  test "the preamble asks a needs-help line for the question and a recommendation (GEA-10619)" do
    assert stage("_preamble.md") =~ "SYMPHONY_NEEDS_HELP: <the blocker, in one sentence> Ask: <"
    assert stage("_preamble.md") =~ "Recommend: <"
  end

  test "no stage authorizes Linear with a key the box does not set" do
    # The agent box sets LINEAR_API_KEY only; other hosts may set only
    # LINEAR_API_KEY_AUTOMATION. A header that names either key alone sends an
    # empty key on one of them.
    for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) do
      content = File.read!(path)
      name = Path.basename(path)

      refute content =~ ~r/Authorization: \$LINEAR_API_KEY_AUTOMATION\b/,
             "#{name} still authorizes with $LINEAR_API_KEY_AUTOMATION alone"

      refute content =~ ~r/Authorization: \$LINEAR_API_KEY\b/,
             "#{name} authorizes with $LINEAR_API_KEY alone"
    end
  end
end
