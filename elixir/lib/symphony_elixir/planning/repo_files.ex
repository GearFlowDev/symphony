defmodule SymphonyElixir.Planning.RepoFiles do
  @moduledoc """
  The real file tree of the repository an issue's plan touches (GEA-11074).

  The Planner is a no-tools session that runs before any slot is leased, so it
  guessed every path in `touches`. On GEA-10461 it named `lib/app/...` files that
  do not exist, the worker would not close rows against them, and four turns
  graded every row `missing` before the run parked for a person.

  The tree comes from the repository's read-only copy on this machine,
  `$GEARFLOW_WORKSPACE/local-dev/<repo>-ref`, at `origin/main`. With no such copy,
  or no repository to route to, there is no tree, and the plan is made as before.
  """

  require Logger

  alias SymphonyElixir.Workspace

  @type tree :: %{repo: String.t(), files: MapSet.t(String.t()), dirs: MapSet.t(String.t())}

  # The Planner sees directories, not files: 500-odd lines on the product repos,
  # where the file list is 6,000. These never hold a planned change.
  @skipped_dirs ~r{(^|/)(node_modules|deps|_build|\.git|priv/static|vendor)(/|$)}
  @max_prompt_depth 4

  @doc """
  The tree for the issue's repository, or `:unavailable`.

  The repository is the one the `before_run` hook would lease a slot for: the
  PR's repository, else the issue's `2.0` / `3.0` label.
  """
  @spec load(map(), keyword()) :: {:ok, tree()} | :unavailable
  def load(issue, opts \\ []) do
    labels = Map.get(issue, :labels) || Map.get(issue, "labels") || []

    with repo when is_binary(repo) and repo != "" <- Workspace.repo_name(labels, opts[:pr_url]),
         ws when is_binary(ws) and ws != "" <- System.get_env("GEARFLOW_WORKSPACE"),
         ref = Path.join([ws, "local-dev", repo <> "-ref"]),
         true <- File.dir?(Path.join(ref, ".git")),
         {:ok, files} <- ls_tree(ref) do
      {:ok, from_files(repo, files)}
    else
      _ -> :unavailable
    end
  end

  defp ls_tree(ref) do
    Enum.find_value(["origin/main", "HEAD"], {:error, :ls_tree_failed}, fn rev ->
      case System.cmd("git", ["-C", ref, "ls-tree", "-r", "--name-only", rev], stderr_to_stdout: true) do
        {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
        _ -> nil
      end
    end)
  rescue
    error ->
      Logger.warning("RepoFiles: git ls-tree failed in #{ref}: #{Exception.message(error)}")
      {:error, :ls_tree_failed}
  end

  @doc "Build a tree from a list of repository-relative file paths."
  @spec from_files(String.t(), [String.t()]) :: tree()
  def from_files(repo, files) do
    dirs =
      files
      |> Enum.flat_map(&ancestors/1)
      |> MapSet.new()

    %{repo: repo, files: MapSet.new(files), dirs: dirs}
  end

  defp ancestors(path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(&Path.join(&2, &1))
  end

  @doc """
  The directory outline the Planner reads, one directory per line, to
  #{@max_prompt_depth} levels deep.
  """
  @spec outline(tree()) :: String.t()
  def outline(%{dirs: dirs}) do
    dirs
    |> Enum.reject(&Regex.match?(@skipped_dirs, &1))
    |> Enum.filter(&(length(Path.split(&1)) <= @max_prompt_depth))
    |> Enum.sort()
    |> Enum.join("\n")
  end

  @doc """
  The paths in the plan's `touches` and `tests` that cannot be right.

  A path is right when the file exists, when it names an existing directory, or
  when it is a new file in an existing directory. A new file one directory down
  is right too, when that directory's parent is at least two levels deep
  (`lib/gf_web/live/new_thing/index.ex`). A new directory straight under a
  top-level one is how a guessed namespace looks (`lib/app/foo.ex`), so it is not.
  """
  @spec unknown_paths(map(), tree()) :: [String.t()]
  def unknown_paths(%{"rows" => rows}, tree) when is_list(rows) do
    rows
    |> Enum.flat_map(&(List.wrap(&1["touches"]) ++ List.wrap(&1["tests"])))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reject(&known?(&1, tree))
  end

  def unknown_paths(_plan_json, _tree), do: []

  defp known?(path, %{files: files, dirs: dirs}) do
    path = path |> String.trim() |> String.trim_leading("./") |> String.trim_trailing("/")
    parent = Path.dirname(path)
    grandparent = Path.dirname(parent)

    MapSet.member?(files, path) or MapSet.member?(dirs, path) or MapSet.member?(dirs, parent) or
      (MapSet.member?(dirs, grandparent) and length(Path.split(grandparent)) >= 2)
  end

  @doc """
  Real files that share a basename with each unknown path, at most three each,
  so a re-plan can correct a path rather than guess again.
  """
  @spec suggestions([String.t()], tree()) :: %{String.t() => [String.t()]}
  def suggestions(paths, %{files: files}) do
    by_base = Enum.group_by(files, &Path.basename/1)

    Map.new(paths, fn path ->
      {path, by_base |> Map.get(Path.basename(path), []) |> Enum.sort() |> Enum.take(3)}
    end)
  end
end
