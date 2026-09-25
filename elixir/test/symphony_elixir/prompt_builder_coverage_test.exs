defmodule SymphonyElixir.PromptBuilderCoverageTest do
  use SymphonyElixir.TestSupport

  defp stages_dir, do: Workflow.stages_directory()

  defp write_stages!(files) do
    dir = stages_dir()
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, content} -> File.write!(Path.join(dir, name), content) end)
    dir
  end

  defp issue(attrs \\ []) do
    struct(
      %Issue{
        id: "id-1",
        identifier: "GEA-1",
        title: "Title",
        description: "Body",
        state: "In Progress",
        url: "https://example.org/GEA-1",
        labels: []
      },
      attrs
    )
  end

  describe "build_phase_prompt/3" do
    test "falls back to a generic instruction when the phase has no stage section and no preamble" do
      write_stages!(%{"01-plan.md" => "## Step 1: Plan\n\nPlan things."})

      assert PromptBuilder.build_phase_prompt(issue(), "Deploy") == "---\n\nComplete the Deploy phase."
    end

    test "renders preamble and phase section with issue vars and rows" do
      write_stages!(%{
        "_preamble.md" => "Issue {{ issue.identifier }} attempt={{ attempt }} pr={{ existing_pr_url }}",
        "01-exec.md" => "## Step 1: Implement\n\nRows:\n{{ assigned_rows_md }}\nPlan:\n{{ plan_rows_md }}\n## Step 2: Other\nnope"
      })

      rows = [
        %{id: "r1", description: "atom keyed", state: "done", tests: "test/one_test.exs", touches: [], rationale: nil}
      ]

      prompt =
        PromptBuilder.build_phase_prompt(issue(), "Implement",
          attempt: 2,
          existing_pr_url: "https://github.com/o/r/pull/1",
          assigned_rows: rows,
          plan_rows: []
        )

      assert prompt =~ "Issue GEA-1 attempt=2 pr=https://github.com/o/r/pull/1"
      assert prompt =~ "- **r1** (done): atom keyed"
      assert prompt =~ "  - Tests: test/one_test.exs"
      refute prompt =~ "Touches:"
      refute prompt =~ "nope"
    end

    test "a row missing every field renders defaults" do
      write_stages!(%{"01-exec.md" => "## Implement\n{{ assigned_rows_md }}"})

      prompt = PromptBuilder.build_phase_prompt(issue(), "Implement", assigned_rows: [%{}])
      assert prompt =~ "- **?** (missing):"
    end
  end

  describe "build_continuation_prompt/4" do
    test "uses the default prompt when there is no stages directory" do
      File.rm_rf!(stages_dir())

      prompt = PromptBuilder.build_continuation_prompt(issue(), 2, 5, [])
      assert prompt =~ "Continuation guidance (turn 2/5)"
      assert prompt =~ "gh pr list --head"
      refute prompt =~ "New comments on the Linear issue"
    end

    test "uses the default prompt with comments when stages have no continuation template" do
      write_stages!(%{"01-a.md" => "## A"})

      comments = [
        %{created_at: ~U[2026-09-25 13:45:00Z], author: "Ann", body: "please rebase"},
        %{author: "Bob", body: "no time"}
      ]

      prompt = PromptBuilder.build_continuation_prompt(issue(), 3, 9, comments)
      assert prompt =~ "Continuation guidance (turn 3/9)"
      assert prompt =~ "[13:45 UTC] Ann: please rebase"
      assert prompt =~ "[?] Bob: no time"
    end

    test "uses the staged _continuation.md template when present" do
      write_stages!(%{"_continuation.md" => "Turn {{turn_number}} of {{max_turns}}{{comments_section}}"})

      assert PromptBuilder.build_continuation_prompt(issue(), 4, 7, []) == "Turn 4 of 7"
    end
  end

  describe "build_phase_continuation_prompt/6" do
    test "without rows, completion is the posted report" do
      prompt = PromptBuilder.build_phase_continuation_prompt(issue(), "Test", 2, 4, [])

      assert prompt =~ "Continuation guidance (turn 2/4)"
      assert prompt =~ "**Test phase only**"
      assert prompt =~ "If the Test phase is already complete"
      refute prompt =~ "Your assigned rows"
    end

    test "with rows, completion is every row done, and comments are shown" do
      rows = [%{"id" => "r9", "description" => "close it", "state" => "partial", "depends_on" => ["r1", "r2"]}]
      comments = [%{created_at: ~U[2026-09-25 08:05:00Z], author: "Cy", body: "hi"}]

      prompt =
        PromptBuilder.build_phase_continuation_prompt(issue(), "Implement", 1, 3, comments, assigned_rows: rows)

      assert prompt =~ "Your assigned rows"
      assert prompt =~ "- **r9** (partial): close it"
      assert prompt =~ "  - Depends on: r1, r2"
      assert prompt =~ "EVERY row above is `done`"
      assert prompt =~ "[08:05 UTC] Cy: hi"
    end

    test "an empty row list falls back to the report completion test" do
      prompt = PromptBuilder.build_phase_continuation_prompt(issue(), "Review", 1, 2, [], assigned_rows: [])
      assert prompt =~ "If the Review phase is already complete"
    end
  end

  describe "build_retask_prompt/4" do
    test "uses the default template without a stages directory" do
      File.rm_rf!(stages_dir())

      prompt = PromptBuilder.build_retask_prompt(issue(identifier: "GEA-42"), ["Ship"], ["Investigate", "Implement"])

      assert prompt =~ "You are continuing work on GEA-42."
      assert prompt =~ "- Investigate\n- Implement"
      assert prompt =~ "### Ship (INCOMPLETE)\n\nComplete the Ship phase."
    end

    test "falls back to 'unknown' when the issue has no identifier" do
      File.rm_rf!(stages_dir())
      prompt = PromptBuilder.build_retask_prompt(%{identifier: nil}, [], [])
      assert prompt =~ "continuing work on unknown."
    end

    test "uses stage sections, the _retask template and the preamble's context sections" do
      preamble = """
      # Preamble

      ## CRITICAL: Working Directory
      cd /slot
      ## Scope
      scope stuff
      ## Environment Notes
      PORT=4000
      {% if issue %}
      templated
      {% endif %}
      """

      write_stages!(%{
        "_preamble.md" => preamble,
        "_retask.md" => "RETASK {{identifier}}\nDone:\n{{completed_phases_list}}\nTodo:\n{{missing_phases_content}}",
        "02-ship.md" => "## Step 5: Ship\n\nOpen the PR.\n"
      })

      prompt = PromptBuilder.build_retask_prompt(issue(identifier: "GEA-7"), ["Ship", "Deploy"], ["Test"])

      [context, body] = String.split(prompt, "\n\n---\n\n", parts: 2)
      assert context =~ "## CRITICAL: Working Directory\ncd /slot"
      assert context =~ "## Environment Notes\nPORT=4000"
      refute context =~ "scope stuff"
      refute context =~ "templated"
      refute context =~ "Guardrails"

      assert body =~ "RETASK GEA-7"
      assert body =~ "Done:\n- Test"
      assert body =~ "### Ship (INCOMPLETE)\n\n## Step 5: Ship\n\nOpen the PR."
      assert body =~ "### Deploy (INCOMPLETE)\n\nComplete the Deploy phase."
    end

    test "a preamble with none of the context sections adds nothing" do
      write_stages!(%{"_preamble.md" => "just text"})
      prompt = PromptBuilder.build_retask_prompt(issue(), [], [])
      assert String.starts_with?(prompt, "You are continuing work on GEA-1.")
    end
  end
end
