defmodule SymphonyElixir.ReviewThreads do
  @moduledoc """
  Says whose move each unresolved review thread on a PR waits for.

  The review gate counted every unresolved thread as work for a worker. A Resolve
  Review worker replies on a thread and stops; CodeRabbit reads the reply and resolves
  the thread some minutes later. Until it does, the thread is unresolved, so every poll
  sent another Resolve Review to the same head. Each one found its reply already posted,
  pushed nothing, and the no-progress breaker parked the issue. GEA-10677 parked at
  22:13Z after three replies on one thread at 22:06Z, 22:10Z and 22:12Z; CodeRabbit
  resolved that thread at 22:18Z, and CI went red at 22:14Z, after the park (GEA-10826).

  A thread's reviewer is the author of its first comment. `classify/2` sorts each
  unresolved thread:

    * `:ours` — the last comment is the reviewer's, so a worker owes an answer.
    * `:theirs` — the last comment is someone else's reply, younger than
      `@reply_grace_seconds`. The reviewer owes the next move, so the issue waits.
    * A reply older than the grace counts as `:ours`: the reviewer did not answer, and a
      worker must look again (and ask for help if the reviewer is stuck).

  `gh_fun` runs a `gh` argument list and returns `{output, exit_status}`.
  """

  # CodeRabbit answered GEA-10677's replies in 6 to 12 minutes.
  @reply_grace_seconds 1800

  @type gh_fun :: ([String.t()] -> {String.t(), non_neg_integer()})
  @type tally :: %{ours: non_neg_integer(), theirs: non_neg_integer()}

  @doc false
  @spec reply_grace_seconds() :: pos_integer()
  def reply_grace_seconds, do: @reply_grace_seconds

  @doc """
  Read the PR's review threads and `classify/2` them. A `gh` read that fails counts no
  thread, like every other ship gate read: a transient `gh` error must never wedge a
  finished issue.
  """
  @spec snapshot({String.t(), String.t()}, gh_fun(), DateTime.t()) :: tally()
  def snapshot({repo, number}, gh_fun, now \\ DateTime.utc_now()) do
    [owner, name] = String.split(repo, "/", parts: 2)

    query =
      ~s|query { repository(owner:"#{owner}", name:"#{name}") { pullRequest(number:#{number}) { reviewThreads(first:100) { nodes { isResolved | <>
        "first: comments(first:1) { nodes { author { login } } } " <>
        "last: comments(last:1) { nodes { author { login } createdAt } } } } } } }"

    with {output, 0} <- gh_fun.(["api", "graphql", "-f", "query=#{query}"]),
         {:ok, decoded} <- Jason.decode(output),
         threads when is_list(threads) <- get_in(decoded, ["data", "repository", "pullRequest", "reviewThreads", "nodes"]) do
      classify(threads, now)
    else
      _ -> %{ours: 0, theirs: 0}
    end
  rescue
    _ -> %{ours: 0, theirs: 0}
  end

  @doc "Tally the unresolved threads of a decoded `reviewThreads.nodes` list."
  @spec classify([map()], DateTime.t()) :: tally()
  def classify(threads, now) do
    threads
    |> Enum.reject(&Map.get(&1, "isResolved"))
    |> Enum.reduce(%{ours: 0, theirs: 0}, fn thread, tally ->
      Map.update!(tally, whose_move(thread, now), &(&1 + 1))
    end)
  end

  defp whose_move(thread, now) do
    reviewer = login(thread, "first")
    last = List.first(get_in(thread, ["last", "nodes"]) || []) || %{}

    if is_binary(reviewer) and login(thread, "last") not in [nil, reviewer] and fresh?(last["createdAt"], now),
      do: :theirs,
      else: :ours
  end

  defp login(thread, which) do
    case get_in(thread, [which, "nodes"]) do
      [%{"author" => %{"login" => login}} | _] when is_binary(login) -> login
      _ -> nil
    end
  end

  defp fresh?(created_at, now) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, at, _} -> DateTime.diff(now, at) < @reply_grace_seconds
      _ -> false
    end
  end

  defp fresh?(_created_at, _now), do: false
end
