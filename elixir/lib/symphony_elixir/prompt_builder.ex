defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Workflow.StageLoader

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "existing_pr_url" => Keyword.get(opts, :existing_pr_url),
        "existing_pr_branch" => Keyword.get(opts, :existing_pr_branch),
        "assigned_rows_md" => render_rows_md(Keyword.get(opts, :assigned_rows)),
        "plan_rows_md" => render_rows_md(Keyword.get(opts, :plan_rows))
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @doc """
  Builds a single-phase prompt: preamble + issue context + one phase's instructions.

  Used in the discrete-phase model where each agent run handles exactly one phase.
  """
  @spec build_phase_prompt(map(), String.t(), keyword()) :: String.t()
  def build_phase_prompt(issue, phase_name, opts \\ []) do
    stages_dir = Workflow.stages_directory()
    stages = StageLoader.load_stages(stages_dir)

    issue_map = issue |> Map.from_struct() |> to_solid_map()
    assigned_rows_md = render_rows_md(Keyword.get(opts, :assigned_rows))
    plan_rows_md = render_rows_md(Keyword.get(opts, :plan_rows))

    template_vars = %{
      "attempt" => Keyword.get(opts, :attempt),
      "issue" => issue_map,
      "existing_pr_url" => Keyword.get(opts, :existing_pr_url),
      "existing_pr_branch" => Keyword.get(opts, :existing_pr_branch),
      "assigned_rows_md" => assigned_rows_md,
      "plan_rows_md" => plan_rows_md
    }

    # Render the preamble through Solid for issue context
    preamble =
      stages
      |> Map.get("_preamble.md", "")
      |> render_solid(template_vars)

    # Get this phase's instructions
    phase_md =
      case StageLoader.phase_content(stages, phase_name) do
        nil -> "Complete the #{phase_name} phase."
        content -> render_solid(content, template_vars)
      end

    [preamble, "---", phase_md]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp render_solid("", _vars), do: ""

  defp render_solid(template, vars) do
    template
    |> Solid.parse!()
    |> Solid.render!(vars, @render_opts)
    |> IO.iodata_to_binary()
  end

  defp render_rows_md(nil), do: ""
  defp render_rows_md([]), do: ""

  defp render_rows_md(rows) when is_list(rows) do
    Enum.map_join(rows, "\n\n", fn row ->
      id = Map.get(row, "id") || Map.get(row, :id) || "?"
      desc = Map.get(row, "description") || Map.get(row, :description) || ""
      touches = Map.get(row, "touches") || Map.get(row, :touches) || []
      tests = Map.get(row, "tests") || Map.get(row, :tests) || []
      deps = Map.get(row, "depends_on") || Map.get(row, :depends_on) || []
      state = Map.get(row, "state") || Map.get(row, :state) || "missing"
      rationale = Map.get(row, "rationale") || Map.get(row, :rationale)

      lines = [
        "- **#{id}** (#{state}): #{desc}",
        format_list_line("Touches", touches),
        format_list_line("Tests", tests),
        format_list_line("Depends on", deps),
        if(rationale, do: "  - Note: #{rationale}", else: nil)
      ]

      lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    end)
  end

  defp format_list_line(_label, []), do: nil

  defp format_list_line(label, items) when is_list(items) do
    "  - #{label}: #{Enum.join(items, ", ")}"
  end

  # Plan rows are JSON edited by humans as well as the planner; a bare string
  # where a list belongs shouldn't crash the whole dispatch (observed
  # 2026-07-17: hand-amended row with tests: "..." function-claused every
  # retry until the row was rewritten).
  defp format_list_line(label, item) when is_binary(item), do: format_list_line(label, [item])

  @doc """
  Builds a continuation prompt for turn N+.
  Uses staged _continuation.md template if available, otherwise falls back to default.
  """
  @spec build_continuation_prompt(map(), pos_integer(), pos_integer(), [map()]) :: String.t()
  def build_continuation_prompt(issue, turn_number, max_turns, comments) do
    stages_dir = Workflow.stages_directory()

    if File.dir?(stages_dir) do
      stages = StageLoader.load_stages(stages_dir)

      case StageLoader.assemble_continuation(stages, turn_number, max_turns, comments) do
        nil -> default_continuation_prompt(issue, turn_number, max_turns, comments)
        prompt -> prompt
      end
    else
      default_continuation_prompt(issue, turn_number, max_turns, comments)
    end
  end

  @doc """
  Continuation for a single-phase dispatch: keep the agent inside its phase
  instead of the generic (Implement-flavored) continuation template.
  """
  @spec build_phase_continuation_prompt(
          map(),
          String.t(),
          pos_integer(),
          pos_integer(),
          [map()],
          keyword()
        ) :: String.t()
  def build_phase_continuation_prompt(_issue, phase, turn_number, max_turns, comments, opts \\ []) do
    """
    Continuation guidance (turn #{turn_number}/#{max_turns}):

    You were dispatched for the **#{phase} phase only**. This is the same session
    as turn 1 — your #{phase} instructions are already in your context.
    #{format_comments_section(comments)}
    #{phase_completion_test(phase, Keyword.get(opts, :assigned_rows))}

    Do NOT implement plan rows, start other phases, or repeat completed work.
    Do NOT look for more work. Do NOT expand scope.
    """
  end

  # A dispatch that carries assigned rows is done when THE ROWS are done, and
  # nothing else says so. The old wording offered "or your fix is pushed" as an
  # alternative completion test, and two re-dispatched row-closers took it:
  # a commit from an earlier dispatch was already on the branch, so both ended
  # every turn without touching the rows they were sent to close, which sat at
  # `partial` (first Fly run, GEA-9699 via GEA-9889, 2026-09-22).
  defp phase_completion_test(phase, rows) when is_list(rows) and rows != [] do
    """
    Your assigned rows, with the status the grader last gave each one:

    #{render_rows_md(rows)}

    This phase is complete when EVERY row above is `done` — that test and no
    other. A pushed commit, an open PR and green CI do NOT complete a row; a row
    left `partial` or `missing` is open work even if the branch already carries
    your earlier commits. If any row above is still open, resume the #{phase}
    phase and close it. End your turn with no further action only when every row
    is done.
    """
  end

  defp phase_completion_test(phase, _rows) do
    """
    If the #{phase} phase is already complete (your report or verdict is
    posted), end your turn now with no further action. Otherwise resume the
    #{phase} phase from where you left off.
    """
  end

  defp default_continuation_prompt(_issue, turn_number, max_turns, comments) do
    comments_section = format_comments_section(comments)

    """
    Continuation guidance (turn #{turn_number}/#{max_turns}):

    The previous turn completed normally, but the Linear issue is still in an active state.
    Resume from the current workspace state — do not restart from scratch.
    #{comments_section}
    FIRST, check if a PR already exists for this branch:
      gh pr list --head "$(git branch --show-current)" --json number,url,state --jq '.[0]'

    If a PR exists:
    1. If CI failed (`gh pr checks <number>`), fix it and push.
    2. If there are review comments, address them and push.
    3. Otherwise keep closing your assigned plan rows. You were dispatched again
       because the grader found open rows, so green CI does NOT mean "done" — the
       grader decides completion, not you.

    If no PR exists, continue working toward shipping one (it will be opened as a draft).

    Never change the PR's draft state: do NOT run `gh pr ready` (with or without
    `--undo`). The PR stays a draft until the grader marks the plan complete and a
    human promotes it; leaving it a draft is what keeps the issue from flipping to
    In Review and pulling reviewers onto unfinished work.

    Do NOT re-run tests or post additional test reports if the PR is already open and CI is passing.
    Do NOT look for more work. Do NOT expand scope.
    """
  end

  @doc """
  Builds a targeted retask prompt for only the missing phases.

  Instead of the full 8000-line workflow prompt, this produces a focused ~200-line
  prompt that tells the agent exactly which phases to complete and skips everything
  already done.
  """
  @spec build_retask_prompt(map(), [String.t()], [String.t()], keyword()) :: String.t()
  def build_retask_prompt(issue, missing_phases, completed_phases, _opts \\ []) do
    stages_dir = Workflow.stages_directory()
    stages = StageLoader.load_stages(stages_dir)

    # Build completed phases list
    completed_list =
      completed_phases
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    # Build missing phases content by extracting each phase's section from the stage files
    missing_content =
      missing_phases
      |> Enum.map(fn phase ->
        content = StageLoader.phase_content(stages, phase)

        if content do
          "### #{phase} (INCOMPLETE)\n\n#{content}"
        else
          "### #{phase} (INCOMPLETE)\n\nComplete the #{phase} phase."
        end
      end)
      |> Enum.join("\n\n---\n\n")

    # Load retask template or use default
    template = StageLoader.load_retask_template(stages_dir) || default_retask_template()

    # Render the template with issue context
    identifier = issue_identifier(issue)

    prompt =
      template
      |> String.replace("{{identifier}}", identifier)
      |> String.replace("{{completed_phases_list}}", completed_list)
      |> String.replace("{{missing_phases_content}}", missing_content)

    # Prepend essential context (slot info, env vars) from preamble if available
    preamble_context = extract_preamble_context(stages)

    if preamble_context != "" do
      preamble_context <> "\n\n---\n\n" <> prompt
    else
      prompt
    end
  end

  defp issue_identifier(%{identifier: id}) when is_binary(id), do: id
  defp issue_identifier(_), do: "unknown"

  defp default_retask_template do
    """
    You are continuing work on {{identifier}}.

    ## IMPORTANT: Do NOT repeat completed work

    These phases are DONE — do not redo them:
    {{completed_phases_list}}

    ## Remaining work

    Complete ONLY these phases:

    {{missing_phases_content}}

    Do NOT re-investigate, re-implement, or re-create the PR unless explicitly listed above.
    Do NOT look for more work. Do NOT expand scope.
    """
  end

  defp extract_preamble_context(stages) do
    case Map.get(stages, "_preamble.md") do
      nil ->
        ""

      preamble ->
        # Extract only the Working Directory and Environment sections from the preamble.
        # Skip everything else (scope, issue context, continuation) because those contain
        # unrendered Solid template variables and instructions that conflict with retask
        # (e.g. "if PR exists, stop immediately").
        sections = extract_sections(preamble, ["## CRITICAL: Working Directory", "## Environment Notes", "## Guardrails"])
        sections |> Enum.join("\n\n") |> String.trim()
    end
  end

  defp extract_sections(text, headings) do
    lines = String.split(text, "\n")

    Enum.flat_map(headings, fn heading ->
      case find_section(lines, heading) do
        nil -> []
        section -> [section]
      end
    end)
  end

  defp find_section(lines, heading) do
    case Enum.drop_while(lines, fn line -> not String.starts_with?(line, heading) end) do
      [] ->
        nil

      [_heading_line | rest] ->
        # Take lines until the next ## heading or Solid template block
        body =
          rest
          |> Enum.take_while(fn line ->
            not (String.starts_with?(line, "## ") and not String.starts_with?(line, "### ")) and
              not String.starts_with?(String.trim(line), "{%")
          end)

        [heading | body] |> Enum.join("\n") |> String.trim()
    end
  end

  defp format_comments_section([]), do: ""

  defp format_comments_section(comments) do
    formatted =
      comments
      |> Enum.map(fn c ->
        time = if c[:created_at], do: Calendar.strftime(c.created_at, "%H:%M UTC"), else: "?"
        "  [#{time}] #{c[:author]}: #{c[:body]}"
      end)
      |> Enum.join("\n")

    """

    ## New comments on the Linear issue (from your team — read carefully and follow any instructions):
    #{formatted}

    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
