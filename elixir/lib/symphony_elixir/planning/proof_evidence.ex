defmodule SymphonyElixir.Planning.ProofEvidence do
  @moduledoc """
  Proof the Grader cannot find in the diff: the PR's CI and review state on its
  head, and what was posted to the issue while a dispatch ran.

  A row can ask for proof that lives outside `git diff`: "run it green",
  "request the CodeRabbit review and resolve its threads", "post screenshots on
  the issue". Without these channels the Grader graded every such row
  `partial` on every pass, and the Implement worker it sent back had nothing
  left to change. GEA-10457 (R10, the review row) and GEA-10459 (R8, "run it
  green") both returned to the Grader at the same head until the no-progress
  breaker parked them (GEA-10667, 2026-09-30).

  Each reader is best-effort: a failure gives `nil`, and the Grader loses that
  section only.
  """

  require Logger

  alias SymphonyElixir.Linear.Client

  @gh_timeout_ms 30_000
  @passed ~w(SUCCESS NEUTRAL SKIPPED)
  @comment_body_limit 1_500
  @comments_limit 15

  @doc """
  The "## PR state on the head" section for the PR at `pr_url`, or nil.

  `gh_fun` runs a `gh` argument list and returns `{output, exit_status}`.
  """
  @spec pr_state_section(String.t() | nil, (list(String.t()) -> {String.t(), integer()})) :: String.t() | nil
  def pr_state_section(pr_url, gh_fun \\ &gh/1) do
    with url when is_binary(url) <- pr_url,
         {repo, number} <- pr_ref(url),
         {:ok, pr} <- pr_view(repo, number, gh_fun) do
      format_pr_state(pr, unresolved_threads(repo, number, gh_fun), latest_coderabbit_review(repo, number, gh_fun))
    else
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("ProofEvidence.pr_state_section failed: #{Exception.message(error)}")
      nil
  end

  @doc """
  Render a decoded `gh pr view --json headRefOid,statusCheckRollup,comments`
  result. `unresolved` is the unresolved review-thread count, or nil when it
  could not be read. `review` is CodeRabbit's latest review as the REST API
  gives it (`state`, `commit_id`), or nil.
  """
  @spec format_pr_state(map(), non_neg_integer() | nil, map() | nil) :: String.t()
  def format_pr_state(pr, unresolved, review) do
    head = pr["headRefOid"] || ""
    short = String.slice(head, 0, 12)

    lines =
      [
        "Head: `#{short}`",
        checks_line(pr["statusCheckRollup"] || []),
        coderabbit_line(review, head),
        threads_line(unresolved)
      ] ++ review_request_lines(pr["comments"] || [])

    "## PR state on the head (live from GitHub)\n\n" <>
      "Use this for rows whose proof is a green run, a review, or resolved review threads. " <>
      "CI runs the whole test suite on the head, so all checks passed on the head is a green run " <>
      "of every test on the branch.\n\n" <>
      Enum.map_join(lines, "\n", &("- " <> &1))
  end

  defp checks_line([]), do: "CI checks on the head: none reported yet."

  defp checks_line(checks) do
    grouped = Enum.group_by(checks, &check_bucket/1, &check_name/1)
    passed = Map.get(grouped, :passed, [])
    failed = Map.get(grouped, :failed, [])
    pending = Map.get(grouped, :pending, [])

    "CI checks on the head: #{length(passed)} passed, #{length(failed)} failed" <>
      names(failed) <> ", #{length(pending)} pending" <> names(pending) <> "."
  end

  defp names([]), do: ""
  defp names(list), do: " (" <> Enum.join(Enum.uniq(list), ", ") <> ")"

  defp check_name(check), do: check["name"] || check["context"] || "check"

  # A CheckRun reports `status` + `conclusion`; a StatusContext reports `state`.
  defp check_bucket(%{"state" => state}) when is_binary(state) do
    cond do
      state in @passed -> :passed
      state in ["PENDING", "EXPECTED"] -> :pending
      true -> :failed
    end
  end

  defp check_bucket(check) do
    cond do
      check["status"] not in [nil, "COMPLETED"] -> :pending
      check["conclusion"] in @passed -> :passed
      true -> :failed
    end
  end

  # The commit comes from the REST reviews API: `gh pr view`'s `latestReviews`
  # returns an empty commit oid, which would read every review as stale.
  defp coderabbit_line(%{"state" => state, "commit_id" => oid}, head) when is_binary(oid) and oid != "" do
    where = if oid == head, do: "the head", else: "`#{String.slice(oid, 0, 12)}`, not the head"
    "CodeRabbit: latest review is #{state} on #{where}."
  end

  defp coderabbit_line(_review, _head), do: "CodeRabbit: no review on this PR, or it could not be read."

  defp threads_line(nil), do: "Unresolved review threads: unknown (could not be read)."
  defp threads_line(n), do: "Unresolved review threads: #{n}."

  defp review_request_lines(comments) do
    comments
    |> Enum.filter(&String.contains?(&1["body"] || "", "@coderabbitai"))
    |> Enum.reject(&coderabbit?(get_in(&1, ["author", "login"])))
    |> Enum.take(-5)
    |> Enum.map(fn c ->
      body = c["body"] |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 80)
      "PR comment by #{get_in(c, ["author", "login"]) || "?"} at #{c["createdAt"]}: `#{body}`"
    end)
  end

  defp coderabbit?(login) when is_binary(login), do: String.starts_with?(login, "coderabbit")
  defp coderabbit?(_), do: false

  @doc """
  The "## Issue comments during this dispatch" section: comments posted on the
  issue at or after `since`, with their image count. Nil when there are none.
  """
  @spec issue_comments_section(list(map()), DateTime.t() | nil) :: String.t() | nil
  def issue_comments_section(comments, since) when is_list(comments) do
    recent =
      comments
      |> Enum.filter(&posted_since?(&1, since))
      |> Enum.take(-@comments_limit)

    case recent do
      [] ->
        nil

      _ ->
        "## Issue comments during this dispatch (live from Linear)\n\n" <>
          "Proof a worker posts to the issue (screenshots, a report) is here, not in the diff. " <>
          "`images` counts the embedded images in each comment.\n\n" <>
          Enum.map_join(recent, "\n\n", &format_comment/1)
    end
  end

  def issue_comments_section(_comments, _since), do: nil

  @doc "Read the issue's comments and render `issue_comments_section/2`, or nil."
  @spec issue_comments_for(String.t() | nil, DateTime.t() | nil, (String.t() -> {:ok, list()} | {:error, term()})) ::
          String.t() | nil
  def issue_comments_for(issue_id, since, fetch \\ &Client.read_all_issue_comments/1) do
    with id when is_binary(id) and id != "" <- issue_id,
         {:ok, comments} <- fetch.(id) do
      issue_comments_section(comments, since)
    else
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("ProofEvidence.issue_comments_for failed: #{Exception.message(error)}")
      nil
  end

  defp posted_since?(%{created_at: %DateTime{} = at}, %DateTime{} = since), do: DateTime.compare(at, since) != :lt
  defp posted_since?(%{created_at: %DateTime{}}, nil), do: true
  defp posted_since?(_comment, _since), do: false

  defp format_comment(%{body: body} = comment) do
    images = length(Regex.scan(~r/!\[[^\]]*\]\([^)]+\)/, body || ""))
    at = comment.created_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    text = body |> String.trim() |> String.slice(0, @comment_body_limit)

    "### #{Map.get(comment, :author, "Unknown")} at #{at} (images: #{images})\n\n```\n#{text}\n```"
  end

  defp pr_view(repo, number, gh_fun) do
    args = ["pr", "view", number, "--repo", repo, "--json", "headRefOid,statusCheckRollup,comments"]

    with {output, 0} <- gh_fun.(args),
         {:ok, %{} = pr} <- Jason.decode(output) do
      {:ok, pr}
    else
      _ -> :error
    end
  end

  # `--paginate` runs the jq once per page, so each page prints its own last
  # CodeRabbit review (or null); the last non-null line is the latest.
  defp latest_coderabbit_review(repo, number, gh_fun) do
    jq = ~s<[.[] | select(.user.login | startswith("coderabbit"))] | last | {state, commit_id}>

    with {output, 0} <- gh_fun.(["api", "repos/#{repo}/pulls/#{number}/reviews", "--paginate", "--jq", jq]),
         line when is_binary(line) <- output |> String.split("\n", trim: true) |> Enum.reject(&(String.trim(&1) == "null")) |> List.last(),
         {:ok, %{} = review} <- Jason.decode(line) do
      review
    else
      _ -> nil
    end
  end

  defp unresolved_threads(repo, number, gh_fun) do
    [owner, name] = String.split(repo, "/", parts: 2)

    query =
      ~s|query { repository(owner:"#{owner}", name:"#{name}") { pullRequest(number:#{number}) | <>
        "{ reviewThreads(first:100) { pageInfo { hasNextPage } nodes { isResolved } } } } }"

    # A count over a partial page is not proof of zero: past 100 threads the
    # count is unknown, and the grader is told so.
    jq =
      "if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage then \"unknown\" " <>
        "else [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length end"

    with {output, 0} <- gh_fun.(["api", "graphql", "-f", "query=#{query}", "--jq", jq]),
         {n, _} <- Integer.parse(String.trim(output)) do
      n
    else
      _ -> nil
    end
  end

  defp pr_ref(pr_url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, pr_url) do
      [_, repo, number] -> {repo, number}
      _ -> :error
    end
  end

  # System.cmd/3 has no timeout; a stalled gh must never hold a grade.
  defp gh(args) do
    task = Task.async(fn -> System.cmd("gh", args, stderr_to_stdout: true) end)

    case Task.yield(task, @gh_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {output, status}
      _ -> {"", 124}
    end
  end
end
