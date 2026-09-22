defmodule SymphonyElixir.Evaluator do
  @moduledoc """
  Post-run evaluation: checks what an agent actually accomplished and produces a quality score.

  All checks are fast (shell commands + one Linear API call). Runs synchronously
  after agent process exits, before the retry decision.
  """

  require Logger

  alias SymphonyElixir.History

  # The branch a Symphony PR targets. The rest of this module already reads
  # `origin/main` for its diff and commit checks; a repo whose trunk is not `main`
  # would need all of them changed together, not this one alone.
  @pr_base_branch "main"

  @default_weights %{
    pr_created: 25,
    ci_passed: 20,
    tests_written: 15,
    evidence_posted: 15,
    workpad_updated: 10,
    diff_non_empty: 10,
    branch_pushed: 5
  }

  @type evaluation :: %{
          pr_created: boolean(),
          pr_url: String.t() | nil,
          ci_status: String.t(),
          files_changed: integer(),
          lines_changed: integer(),
          branch_pushed: boolean(),
          evidence_posted: boolean(),
          workpad_updated: boolean(),
          tests_written: boolean(),
          plan_posted: boolean(),
          simplify_done: boolean(),
          score: integer()
        }

  @doc """
  Run all post-completion checks and return a structured evaluation.
  """
  @spec evaluate(map(), String.t() | nil) :: evaluation()
  def evaluate(run_context, workspace_path) do
    issue_id = run_context[:issue_id]
    branch = run_context[:branch_name] || run_context[:identifier]

    # Resolve actual working directory from pool slot if present
    workspace_path = resolve_workspace_path(workspace_path)

    # Try the actual git branch first, then fall back to Linear branch name and identifier
    pr_result =
      case detect_current_branch(workspace_path) do
        {:ok, current} -> check_pr(workspace_path, current)
        _ -> check_pr(workspace_path, branch)
      end

    pr_result =
      if !pr_result[:exists] and branch != run_context[:identifier] do
        check_pr(workspace_path, run_context[:identifier])
      else
        pr_result
      end

    ci_status = check_ci(workspace_path, pr_result[:number])
    {files, lines} = check_diff(workspace_path)
    pushed = check_branch_pushed(workspace_path, branch)
    {evidence, workpad} = check_linear_comments(issue_id)
    tests = check_tests_written(workspace_path)
    plan = check_plan_posted(issue_id)
    simplify = check_simplify_done(workspace_path, issue_id)

    eval = %{
      pr_created: pr_result[:exists],
      pr_url: pr_result[:url],
      ci_status: ci_status,
      files_changed: files,
      lines_changed: lines,
      branch_pushed: pushed,
      evidence_posted: evidence,
      workpad_updated: workpad,
      tests_written: tests,
      plan_posted: plan,
      simplify_done: simplify,
      score: 0
    }

    %{eval | score: compute_score(eval)}
  end

  @doc """
  Run evaluation and persist results to the run record.
  """
  @spec evaluate_and_record(String.t(), map(), String.t() | nil) :: {:ok, evaluation()} | {:error, term()}
  def evaluate_and_record(run_id, run_context, workspace_path) do
    eval = evaluate(run_context, workspace_path)

    attrs = %{
      eval_score: eval.score,
      eval_pr_created: eval.pr_created,
      eval_pr_url: eval.pr_url,
      eval_ci_status: eval.ci_status,
      eval_files_changed: eval.files_changed,
      eval_lines_changed: eval.lines_changed,
      eval_branch_pushed: eval.branch_pushed,
      eval_evidence_posted: eval.evidence_posted,
      eval_workpad_updated: eval.workpad_updated,
      eval_tests_written: eval.tests_written
    }

    case History.record_evaluation(run_id, attrs) do
      {:ok, _run} -> {:ok, eval}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Evaluation failed for run #{run_id}: #{Exception.message(error)}")
      {:error, error}
  end

  @doc """
  Returns a list of human-readable descriptions of failing checks from an evaluation.
  """
  @spec failing_checks(evaluation()) :: [String.t()]
  def failing_checks(eval) do
    checks = [
      {eval.pr_created, "PR not created"},
      {eval.ci_status == "passed", "CI not passed"},
      {eval.tests_written, "No tests written"},
      {eval.evidence_posted, "No evidence posted"},
      {eval.workpad_updated, "Workpad not updated"},
      {eval.files_changed > 0, "No code changes"},
      {eval.branch_pushed, "Branch not pushed"}
    ]

    for {passing, label} <- checks, !passing, do: label
  end

  # ---------------------------------------------------------------------------
  # Individual checks
  # ---------------------------------------------------------------------------

  @doc """
  The PR for `branch`, opening a ready one when the branch is pushed and has none.
  Returns the PR's URL, or nil when there is nothing to open a PR for.

  WHY THE ORCHESTRATOR OPENS IT AND NOT ONLY THE WORKER. A run that ends with a
  pushed branch and no PR is broken, not handed off — the machine owner's rule of
  2026-09-22 (GEA-9888). GEA-9699 ended exactly that way: commit `9ee9986b` pushed
  and nothing for a person or the harness to judge. The execution stage tells the
  worker to open the PR in the same step as the push; this is what keeps the
  promise when a stall, a retry cap or a park ends the run before it gets there.

  READY, NEVER A DRAFT. Symphony used to hold every PR draft until the plan graded
  complete, on the reasoning that a ready PR trips the PR-opened -> In Review
  automation and pulls CodeRabbit onto half-finished work. That is the behaviour
  the agent pool already lives with, and the hand-off — not the draft flag — is
  where completeness is decided (GEA-9888, decided 2026-09-22).

  Idempotent and best-effort: a no-op with no workspace, no branch, an unpushed
  branch, or a PR that already exists.
  """
  @spec ensure_pr_open(String.t() | nil, String.t() | nil, String.t(), String.t()) ::
          String.t() | nil
  def ensure_pr_open(workspace_path, branch, title, body)
      when is_binary(title) and is_binary(body) do
    ws = resolve_workspace_path(workspace_path)

    # The issue's branch as given — `gh pr list --head <branch>` matches the PR's
    # head whatever the local checkout is on, so this works even when the slot tree
    # is parked on main between dispatches.
    case check_pr(ws, branch) do
      %{exists: true, url: url} when is_binary(url) ->
        url

      _ ->
        open_pr(ws, branch, title, body)
    end
  end

  def ensure_pr_open(_workspace_path, _branch, _title, _body), do: nil

  # A PR needs a pushed branch to point at. An unpushed branch is a run that closed
  # no rows, not a run missing its PR, and `gh pr create` on one would push work
  # nobody graded.
  defp open_pr(ws, branch, title, body) when is_binary(branch) and branch != "" do
    if branch_on_origin?(ws, branch) do
      command =
        "gh pr create --base #{@pr_base_branch} --head #{safe_arg(branch)} " <>
          "--title #{shell_quote(title)} --body #{shell_quote(body)}"

      case run_in_workspace(ws, command) do
        {:ok, output} ->
          url = output |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "http"))
          Logger.info("Evaluator: opened PR for #{branch}: #{inspect(url)}")
          url

        {:error, reason} ->
          Logger.warning("Evaluator: could not open a PR for #{branch}: #{inspect(reason)}")
          nil
      end
    else
      Logger.info("Evaluator: no PR opened for #{branch} — the branch is not pushed")
      nil
    end
  end

  defp open_pr(_ws, _branch, _title, _body), do: nil

  # Is the branch on origin? ASKED OF THE REMOTE, not of `origin/<branch>..HEAD`:
  # between dispatches the slot tree is parked on main, so a local comparison
  # reports a pushed branch as unpushed and the PR never opens — the exact failure
  # this function exists to prevent.
  defp branch_on_origin?(ws, branch) do
    match?({:ok, _}, run_in_workspace(ws, "git ls-remote --exit-code --heads origin #{safe_arg(branch)}"))
  end

  # Single quotes, with the shell's own escape for an embedded one. The title comes
  # from Linear, which accepts every metacharacter a shell reads.
  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp check_pr(workspace_path, branch) do
    case run_in_workspace(workspace_path, "gh pr list --head #{safe_arg(branch)} --json url,number,state --limit 1") do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, [%{"url" => url, "number" => number} | _]} ->
            %{exists: true, url: url, number: number}

          _ ->
            %{exists: false, url: nil, number: nil}
        end

      _ ->
        %{exists: false, url: nil, number: nil}
    end
  end

  defp check_ci(_workspace_path, nil), do: "none"

  defp check_ci(workspace_path, pr_number) do
    case run_in_workspace(workspace_path, "gh pr checks #{pr_number} --json name,state 2>/dev/null") do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, checks} when is_list(checks) ->
            cond do
              Enum.all?(checks, &(&1["state"] == "SUCCESS")) -> "passed"
              Enum.any?(checks, &(&1["state"] == "FAILURE")) -> "failed"
              true -> "pending"
            end

          _ ->
            "none"
        end

      _ ->
        "none"
    end
  end

  defp check_diff(workspace_path) do
    case run_in_workspace(workspace_path, "git diff origin/main --stat 2>/dev/null | tail -1") do
      {:ok, output} ->
        # Parse: " 5 files changed, 120 insertions(+), 30 deletions(-)"
        files =
          case Regex.run(~r/(\d+) files? changed/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        insertions =
          case Regex.run(~r/(\d+) insertions?/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        deletions =
          case Regex.run(~r/(\d+) deletions?/, output) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        {files, insertions + deletions}

      _ ->
        {0, 0}
    end
  end

  defp check_branch_pushed(workspace_path, branch) do
    case run_in_workspace(workspace_path, "git log origin/#{safe_arg(branch)}..HEAD --oneline 2>/dev/null") do
      {:ok, output} ->
        # Empty output means everything is pushed
        String.trim(output) == ""

      _ ->
        false
    end
  end

  defp check_linear_comments(nil), do: {false, false}

  defp check_linear_comments(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
      {:ok, comments} ->
        bodies = Enum.map(comments, & &1.body)
        all_text = Enum.join(bodies, "\n")

        has_screenshots = String.contains?(all_text, "![")
        has_test_results = String.contains?(all_text, "## Test Results")

        # Evidence requires either embedded screenshots or test results with screenshot mention
        evidence =
          has_screenshots or
            (has_test_results and String.contains?(String.downcase(all_text), "screenshot"))

        workpad = String.contains?(all_text, "## Codex Workpad") or String.contains?(all_text, "## Workpad")

        {evidence, workpad}

      _ ->
        {false, false}
    end
  end

  defp check_tests_written(workspace_path) do
    case run_in_workspace(workspace_path, "git diff origin/main --name-only 2>/dev/null") do
      {:ok, output} ->
        files = String.split(output, "\n", trim: true)

        test_files = Enum.filter(files, &test_file?/1)
        source_files = Enum.reject(files, &test_file?/1)

        has_tests = length(test_files) > 0

        if has_tests and length(source_files) > 0 do
          Logger.info("Evaluator: test coverage — #{length(test_files)} test files for #{length(source_files)} source files")
        end

        has_tests

      _ ->
        false
    end
  end

  defp test_file?(file) do
    String.contains?(file, "_test.") or
      String.contains?(file, ".test.") or
      String.contains?(file, "/test/") or
      String.contains?(file, "spec.")
  end

  defp check_plan_posted(nil), do: false

  defp check_plan_posted(issue_id) do
    case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
      {:ok, comments} ->
        all_text = comments |> Enum.map(& &1.body) |> Enum.join("\n")

        String.contains?(all_text, "## Requirements") or
          String.contains?(all_text, "- [ ]") or
          String.contains?(all_text, "## Implementation") or
          String.contains?(all_text, "### Plan")

      _ ->
        false
    end
  end

  defp check_simplify_done(_workspace_path, nil), do: false

  defp check_simplify_done(workspace_path, issue_id) do
    # Check for a commit with "simplify" in the message, or 2+ commits on the branch
    # (the second commit is from the simplify pass even if not named "simplify")
    simplify_commit =
      case run_in_workspace(workspace_path, "git log --oneline origin/main..HEAD 2>/dev/null") do
        {:ok, output} ->
          commits = output |> String.split("\n", trim: true)
          has_simplify_msg = Enum.any?(commits, &String.contains?(String.downcase(&1), "simplify"))
          has_multiple_commits = length(commits) >= 2
          has_simplify_msg or has_multiple_commits

        _ ->
          false
      end

    no_changes_comment =
      case SymphonyElixir.Linear.Client.fetch_all_issue_comments(issue_id) do
        {:ok, comments} ->
          Enum.any?(comments, fn c ->
            String.contains?(String.downcase(c.body), "no simplification needed") or
              String.contains?(String.downcase(c.body), "no changes needed")
          end)

        _ ->
          false
      end

    simplify_commit or no_changes_comment
  end

  # ---------------------------------------------------------------------------
  # Scoring
  # ---------------------------------------------------------------------------

  defp compute_score(eval) do
    weights = @default_weights

    score = 0
    score = if eval.pr_created, do: score + weights.pr_created, else: score
    score = if eval.ci_status == "passed", do: score + weights.ci_passed, else: score
    score = if eval.tests_written, do: score + weights.tests_written, else: score
    score = if eval.evidence_posted, do: score + weights.evidence_posted, else: score
    score = if eval.workpad_updated, do: score + weights.workpad_updated, else: score
    score = if eval.files_changed > 0, do: score + weights.diff_non_empty, else: score
    score = if eval.branch_pushed, do: score + weights.branch_pushed, else: score

    min(score, 100)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_in_workspace(nil, _cmd), do: {:error, :no_workspace}

  defp run_in_workspace(workspace_path, cmd) do
    if File.dir?(workspace_path) do
      case System.cmd("sh", ["-c", cmd], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    else
      {:error, :workspace_not_found}
    end
  end

  defp safe_arg(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_\-\/.]/, "")
  end

  defp safe_arg(_), do: ""

  defp detect_current_branch(nil), do: {:error, :no_workspace}

  defp detect_current_branch(workspace_path) do
    case run_in_workspace(workspace_path, "git branch --show-current 2>/dev/null") do
      {:ok, output} ->
        branch = String.trim(output)
        if branch != "", do: {:ok, branch}, else: {:error, :no_branch}

      _ ->
        {:error, :no_branch}
    end
  end

  # Resolve the actual working directory. Pool-based workspaces contain a
  # `.symphony_slot` file that points to the real git repo directory.
  defp resolve_workspace_path(nil), do: nil

  defp resolve_workspace_path(path) do
    slot_file = Path.join(path, ".symphony_slot")

    if File.exists?(slot_file) do
      case File.read(slot_file) do
        {:ok, content} ->
          case Regex.run(~r/DIRECTORY=(.+)/, content) do
            [_, dir] ->
              resolved = String.trim(dir)

              if File.dir?(resolved) do
                Logger.info("Evaluator: resolved workspace #{path} -> #{resolved}")
                resolved
              else
                path
              end

            _ ->
              path
          end

        _ ->
          path
      end
    else
      path
    end
  end
end
