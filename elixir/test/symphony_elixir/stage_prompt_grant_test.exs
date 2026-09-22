defmodule SymphonyElixir.StagePromptGrantTest do
  @moduledoc """
  The stage prompts tell the agent which grant it holds, where the run stops, and
  that a pull request opens ready (GEA-9888). These assertions read the prompts
  this repository ships, not a fixture, because the prompts are the behaviour.
  """

  use SymphonyElixir.TestSupport

  @stages_dir Path.expand("../../workflow/stages", __DIR__)
  @workflow_md Path.expand("../../WORKFLOW.md", __DIR__)

  defp issue(labels) do
    %Issue{
      id: "issue-1",
      identifier: "GEA-1",
      title: "Sort import events deterministically",
      description: "A page boundary reds unrelated branches.",
      state: "In Progress",
      url: "https://linear.app/gearflow/issue/GEA-1",
      labels: labels
    }
  end

  defp render(labels) do
    previous = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(@workflow_md)
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)
    PromptBuilder.build_phase_prompt(issue(labels), "Implement")
  end

  test "the preamble resolves the issue's grant and names who merges" do
    prompt = render(["auto-symphony"])

    assert prompt =~ "**Grant**: Auto-Merge"
    assert prompt =~ "the harness judges the hand-off and merges"
    assert prompt =~ "You never merge"
  end

  test "an Auto-Build label beside the runner label narrows what the prompt promises" do
    prompt = render(["auto-symphony", "Auto-Build"])

    assert prompt =~ "**Grant**: Auto-Build"
    assert prompt =~ "A person reviews and merges it"
    refute prompt =~ "the harness judges the hand-off and merges"
  end

  test "Auto-Design tells the agent the product questions are its to settle" do
    prompt = render(["auto-symphony", "Auto-Design"])

    assert prompt =~ "**Grant**: Auto-Design"
    assert prompt =~ "Product questions on the way are yours to settle"
  end

  test "every grant is told a run ends at a pull request" do
    for labels <- [["auto-symphony"], ["auto-symphony", "Auto-Build"], ["auto-symphony", "Auto-User"]] do
      prompt = render(labels)
      assert prompt =~ "A run that ends with a pushed branch and no PR is"
    end
  end

  test "no shipped prompt opens a draft pull request" do
    # THE PIN IS THE FLAG, not the word "draft": the execution stage explains in
    # prose why drafts went, and a grep for "draft" would be satisfied by that
    # explanation while the command underneath still carried `--draft`.
    for path <- [@workflow_md | Path.wildcard(Path.join(@stages_dir, "*.md"))] do
      refute File.read!(path) =~ "--draft", "#{Path.relative_to_cwd(path)} still opens a draft PR"
    end
  end

  test "the execution stage opens the PR in the same step as the push" do
    # A push without a PR is the failure this issue exists to make impossible
    # (GEA-9699 ended with a pushed branch and nothing to judge). Splitting the
    # PR back into its own step is the regression, so the pin is the ORDER: the
    # `gh pr create` line must fall inside the push step.
    stage = File.read!(Path.join(@stages_dir, "02-execution.md"))

    push_step = :binary.match(stage, "### Step 4: Push, and open the PR in the same step")
    pr_create = :binary.match(stage, "gh pr create")
    next_step = :binary.match(stage, "### Step 5:")

    assert push_step != :nomatch and pr_create != :nomatch and next_step != :nomatch
    {push_at, _} = push_step
    {create_at, _} = pr_create
    {next_at, _} = next_step

    assert push_at < create_at and create_at < next_at
  end

  test "the runner label is auto-symphony and the retired states are gone" do
    front_matter = File.read!(@workflow_md)

    assert front_matter =~ "- auto-symphony"
    refute front_matter =~ "- symphony-agent"
    refute front_matter =~ "\n    - Shaped\n"
    assert front_matter =~ "working_label: symphony-working"
    assert front_matter =~ "needs_human_state: Shaping"
  end
end
