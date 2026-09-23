defmodule SymphonyElixir.Planning.Auditor do
  @moduledoc """
  Summarizes the WIP branch's existing diff against its base, so the Planner
  can mark rows `partial` or `done` instead of fresh-start `missing` for
  work that's already on the branch.

  Without this, the Planner trusts only the issue body, and the issue body
  is often stale relative to what's been pushed to the WIP branch (sub-agents
  land work; nobody updates the issue body). The Planner then generates a
  plan that reinvents committed code.

  The audit summary is intentionally compact — file list, commit subject
  list, line-count stats — not the full diff. Planner doesn't need the diff
  text; it needs to know "files X, Y, Z have been touched; commits A, B, C
  reference contracts 02-04". The Planner makes the partial/done call from
  there.

  We use `gh` for diff metadata so the Auditor doesn't depend on a slot —
  it can run from the orchestrator dir using the GitHub API.
  """

  require Logger

  @doc """
  Build an audit summary for an issue with an existing PR.

  Returns:
    * `{:ok, summary_string}` — markdown text the Planner can include in its
      user prompt
    * `{:ok, nil}` — issue has no PR; no audit needed (fresh issue)
    * `{:error, reason}` — gh call failed; the caller should treat this as
      "no audit available" and fall back to issue-body-only planning
  """
  @spec audit(map(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def audit(issue, opts \\ []) do
    pr_url = Keyword.get(opts, :pr_url) || lookup_pr_url(issue)

    case pr_url do
      nil ->
        {:ok, nil}

      url ->
        case extract_pr_repo_and_number(url) do
          {:ok, {repo, number}} -> build_summary(repo, number)
          err -> err
        end
    end
  end

  # Cross-repo PR lookup: `gh pr list --search` is repo-scoped to the cwd.
  # The orchestrator usually knows the PR URL already (check_existing_pr/1
  # populates metadata.existing_pr_url) and should pass it via :pr_url opt;
  # this fallback uses `gh search prs` which is global.
  defp lookup_pr_url(issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    if is_binary(identifier) do
      search_open_pr_url(identifier)
    end
  end

  defp search_open_pr_url(identifier) do
    case run([
           "gh",
           "search",
           "prs",
           "--state=open",
           "--json=url",
           "--match=title,body",
           identifier
         ]) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, [%{"url" => url} | _]} -> url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_pr_repo_and_number(url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, url) do
      [_, repo, number] -> {:ok, {repo, number}}
      _ -> {:error, {:bad_pr_url, url}}
    end
  end

  defp build_summary(repo, number) do
    with {:ok, files_json} <- gh_api(repo, number, "files"),
         {:ok, commits_json} <- gh_api(repo, number, "commits") do
      files = Jason.decode!(files_json)
      commits = Jason.decode!(commits_json)
      {:ok, format_summary(files, commits, repo, number)}
    end
  rescue
    error ->
      Logger.warning("Auditor crashed: #{Exception.message(error)}")
      {:error, {:auditor_crash, Exception.message(error)}}
  end

  defp gh_api(repo, number, kind) do
    args =
      case kind do
        "files" ->
          [
            "gh",
            "api",
            "repos/#{repo}/pulls/#{number}/files",
            "--paginate",
            "--jq",
            "[.[] | {path: .filename, additions, deletions, status}]"
          ]

        "commits" ->
          [
            "gh",
            "api",
            "repos/#{repo}/pulls/#{number}/commits",
            "--paginate",
            "--jq",
            "[.[] | {sha: (.sha[:8]), msg: (.commit.message | split(\"\\n\")[0])}]"
          ]
      end

    run(args)
  end

  defp format_summary(files, commits, repo, number) do
    file_lines =
      files
      |> Enum.sort_by(& &1["path"])
      |> Enum.map_join("\n", fn f ->
        status =
          case f["status"] do
            "added" -> "+"
            "removed" -> "-"
            "renamed" -> "~"
            _ -> " "
          end

        "  #{status} #{f["path"]} (+#{f["additions"]}/-#{f["deletions"]})"
      end)

    commit_lines =
      commits
      |> Enum.map_join("\n", fn c -> "  #{c["sha"]} #{c["msg"]}" end)

    """
    PR `#{repo}#PR##{number}` exists with prior work on the branch.
    The diff below is the current state of the branch relative to its base.
    Use this to mark rows `partial` or `done` where the branch already
    covers them.

    ## Files changed (#{length(files)})

    #{file_lines}

    ## Commits (#{length(commits)}; newest first)

    #{commit_lines |> String.split("\n") |> Enum.reverse() |> Enum.join("\n")}

    Heuristic for partial vs done: if a commit's subject names a contract
    (e.g. "Wave 4 Contract 03 — ...") and matching files exist in the diff
    AND the issue body marks that contract `❌ missing`, the contract is
    likely `partial` — there's progress but the issue body hasn't been
    refreshed. Mark `done` only if the diff convincingly covers all
    sub-items the contract calls out.
    """
  end

  @gh_timeout_ms 30_000

  defp run(args) do
    [cmd | rest] = args

    # System.cmd/3 has no timeout, so bound it with a Task — a stalled gh must
    # never block planning. On timeout the Elixir task is killed (the OS process
    # may linger briefly, but orchestration is freed).
    task = Task.async(fn -> System.cmd(cmd, rest, stderr_to_stdout: true) end)

    case Task.yield(task, @gh_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:gh_failed, code, String.slice(output, 0, 1_000)}}
      _ -> {:error, {:gh_timeout, @gh_timeout_ms}}
    end
  rescue
    error -> {:error, {:gh_crash, Exception.message(error)}}
  end
end
