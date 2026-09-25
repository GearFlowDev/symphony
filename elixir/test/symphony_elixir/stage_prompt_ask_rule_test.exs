defmodule SymphonyElixir.StagePromptAskRuleTest do
  @moduledoc """
  A stage prompt that invites a needs-help exit on a question the grant already
  settles stops a run for nothing (GEA-10513). The ask rule lives in gf_engineering
  `CLAUDE.md`; the prompts point to it and do not restate it. These assertions read
  the prompts this repository ships, because the prompts are the behaviour.
  """

  use ExUnit.Case, async: true

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

  test "no stage authorizes Linear with a key the box does not set" do
    # The agent box sets LINEAR_API_KEY only. A header that names
    # LINEAR_API_KEY_AUTOMATION alone sends an empty key there.
    for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) do
      refute File.read!(path) =~ ~r/Authorization: \$LINEAR_API_KEY_AUTOMATION\b/,
             "#{Path.basename(path)} still authorizes with $LINEAR_API_KEY_AUTOMATION alone"
    end
  end
end
