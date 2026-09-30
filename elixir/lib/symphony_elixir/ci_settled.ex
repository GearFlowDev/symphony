defmodule SymphonyElixir.CiSettled do
  @moduledoc """
  Says whether every check on a PR's head has finished, before Symphony hands it off.

  The ship gate used to fail only on explicit failure states, so a PENDING check
  counted as a pass. GEA-10458 was handed off six minutes after a push, and the
  harness refused it on checks twice (GEA-10755). A hand-off the harness refuses costs
  a retask, and each retask costs about three counted dispatches.

  `check/5` answers `{:pending, reason}` in three cases:

    * A check row on the head is not in a finished state.
    * A GitHub Actions run on the head is not `completed`. A queued run has no check
      rows yet, so the rows alone read as a clean sweep.
    * The head has no check rows and no runs at all, and its commit is younger than
      `@register_grace_seconds`. That is a push GitHub has not registered yet.

  A head with no checks after the grace is a repo without CI, and it is settled. A
  `gh` read that fails is skipped, like every other ship gate read: a transient `gh`
  error must never wedge a finished issue.

  `gh_fun` runs a `gh` argument list and returns `{output, exit_status}`.
  """

  # `gh pr checks --json state` values for a check that has not finished.
  @pending_states ~w(PENDING QUEUED IN_PROGRESS WAITING REQUESTED EXPECTED)
  # A push is on the PR within seconds; its workflow runs register within a minute or
  # two. Ten minutes with nothing registered means the repo runs no CI.
  @register_grace_seconds 600

  @type gh_fun :: ([String.t()] -> {String.t(), non_neg_integer()})

  @doc false
  @spec pending_states() :: [String.t()]
  def pending_states, do: @pending_states

  @doc """
  `checks` is the decoded output of `gh pr checks --json name,state,link`, and `head` is
  the PR's full head sha.
  """
  @spec check({String.t(), String.t()}, String.t(), [map()], gh_fun(), DateTime.t()) ::
          :settled | {:pending, String.t()}
  def check({repo, _number}, head, checks, gh_fun, now \\ DateTime.utc_now()) do
    running = Enum.filter(checks, &(Map.get(&1, "state") in @pending_states))

    cond do
      running != [] ->
        {:pending, "#{names(running)} still running on #{short(head)}"}

      (runs = unfinished_runs(repo, head, gh_fun)) != [] ->
        {:pending, "workflow run #{Enum.join(runs, ", ")} not completed on #{short(head)}"}

      checks == [] and young?(repo, head, gh_fun, now) ->
        {:pending, "no check has registered on #{short(head)} yet"}

      true ->
        :settled
    end
  end

  defp unfinished_runs(_repo, "?", _gh_fun), do: []

  defp unfinished_runs(repo, head, gh_fun) do
    case gh_fun.(["api", "repos/#{repo}/actions/runs?head_sha=#{head}&per_page=100"]) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
            runs
            |> Enum.reject(&(Map.get(&1, "status") == "completed"))
            |> Enum.map(&(Map.get(&1, "name") || "unnamed"))

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp young?(_repo, "?", _gh_fun, _now), do: false

  defp young?(repo, head, gh_fun, now) do
    with {out, 0} <- gh_fun.(["api", "repos/#{repo}/commits/#{head}", "-q", ".commit.committer.date"]),
         {:ok, at, _} <- DateTime.from_iso8601(String.trim(out)) do
      DateTime.diff(now, at) < @register_grace_seconds
    else
      _ -> false
    end
  end

  defp names(checks), do: Enum.map_join(checks, ", ", &(Map.get(&1, "name") || "check"))

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
end
