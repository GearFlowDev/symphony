defmodule SymphonyElixir.CiRecovery do
  @moduledoc """
  Recovers a red PR whose failure the diff did not cause, before Fix CI runs.

  Every red check used to dispatch Fix CI, and a Fix CI worker cannot fix a flaky
  test in a file it never touched or a CI runner that died at setup. On Time to first
  fulfilled request a person re-ran the job or updated the branch by hand four times
  in two days (GEA-10757: PRs #4001, #4062 and #4085 on gf_procurement).

  `decide/5` classifies each failed job of the PR's head:

    * `:in_diff` — the job's log names a failure location in a file the diff touches.
    * `:before_tests` — the job failed in a setup step, before its work ran.
    * `:outside_diff` — anything else: the failure names no file of the diff.

  Only an `:in_diff` failure goes straight to Fix CI. Any other red recovers first:

    1. `main` carries the fix — `main` has moved past the head, every failed check is
       green on `main`'s head, and the same check was red on the merge base (or a
       re-run on this head already failed) → merge `main` into the branch.
    2. No re-run on this head yet → re-run the failed jobs once.
    3. Otherwise → Fix CI.

  A recovery in flight (a re-run not finished, a merge not yet on the PR) is a wait,
  never a dispatch. The classifier reads logs by pattern, so it can call a failure
  the diff caused `:outside_diff`. That costs one re-run: the re-run fails again on
  the same head and step 3 sends it to Fix CI. `@max_recoveries` bounds the whole
  chain per plan, so no failure can loop between merge and re-run.

  `gh_fun` runs a `gh` argument list and returns `{output, exit_status}`.
  """

  @max_recoveries 3
  # A merge accepted by GitHub moves the PR head within seconds. A head that has not
  # moved after this long means the merge did nothing, so the record stops holding.
  @merge_settle_seconds 600

  @setup_step ~r/^(set ?up|install|initiali[sz]e|checkout|fetch|restore|cache|download|prepare|start|wait|log ?in|pull|run actions\/)/i
  @job_link ~r{/actions/runs/(\d+)/job/(\d+)}

  @type check :: %{required(String.t()) => term()}
  @type recovery :: %{required(String.t()) => term()}
  @type gh_fun :: ([String.t()] -> {String.t(), non_neg_integer()})
  @type decision ::
          {:fix_ci, String.t()}
          | {:wait, String.t()}
          | {:recover, :merge_main | :rerun, [String.t()], String.t()}

  @doc "The most recoveries one plan gets before every red goes to Fix CI."
  @spec max_recoveries() :: pos_integer()
  def max_recoveries, do: @max_recoveries

  @doc """
  Decide what a red PR needs. `failing` is the failed rows of `gh pr checks --json
  name,state,link`; `recoveries` is the plan's record of earlier recoveries.
  """
  @spec decide({String.t(), String.t()}, String.t(), [check()], [recovery()], gh_fun(), DateTime.t()) :: decision()
  def decide({repo, number}, head, failing, recoveries, gh_fun, now \\ DateTime.utc_now()) do
    names = Enum.map(failing, &Map.get(&1, "name", "check"))

    ctx = %{
      repo: repo,
      number: number,
      head: head,
      names: names,
      listed: Enum.join(names, ", "),
      recoveries: recoveries,
      on_head: Enum.filter(recoveries, &(Map.get(&1, "head") == head)),
      gh: gh_fun
    }

    with :none <- in_flight(ctx, now),
         {:ok, jobs} <- actions_jobs(failing),
         {:ok, run_ids} <- finished_runs(ctx, jobs) do
      classify_and_choose(ctx, jobs, run_ids)
    else
      {:wait, reason} -> {:wait, reason}
      {:fix_ci, reason} -> {:fix_ci, "CI checks failing: #{ctx.listed} — #{reason}"}
    end
  end

  defp classify_and_choose(ctx, jobs, run_ids) do
    diff = diff_files(ctx)

    case Enum.find_value(jobs, &in_diff(ctx, &1, diff)) do
      {name, path} ->
        {:fix_ci, "CI checks failing: #{ctx.listed} — `#{name}` fails at `#{path}`, a file this diff touches"}

      nil ->
        choose(ctx, run_ids, Enum.map_join(jobs, "; ", &describe_job(ctx, &1)))
    end
  end

  defp choose(ctx, run_ids, why) do
    rerun_spent? = Enum.any?(ctx.on_head, &(Map.get(&1, "action") == "rerun"))
    spent = length(ctx.recoveries)

    cond do
      spent >= @max_recoveries ->
        {:fix_ci, "CI checks failing: #{ctx.listed} — #{spent} recoveries already ran on this plan (#{why})"}

      main_carries_fix?(ctx, rerun_spent?) ->
        {:recover, :merge_main, run_ids, "`main` is green on #{ctx.listed} and has moved past this head, so it carries the fix (#{why})"}

      not rerun_spent? ->
        {:recover, :rerun, run_ids, "the failure is outside this diff (#{why})"}

      true ->
        {:fix_ci, "CI checks failing: #{ctx.listed} — the re-run on head `#{short(ctx.head)}` failed again (#{why})"}
    end
  end

  @doc "Run a recovery `decide/5` chose. Returns `:ok` or `{:error, gh_output}`."
  @spec act({String.t(), String.t()}, :merge_main | :rerun, [String.t()], gh_fun()) :: :ok | {:error, String.t()}
  def act({repo, number}, :merge_main, _run_ids, gh_fun) do
    # `update-branch` merges by default; a rebase would rewrite what a reviewer saw.
    case gh_fun.(["pr", "update-branch", number, "--repo", repo]) do
      {_out, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  def act({repo, _number}, :rerun, run_ids, gh_fun) do
    Enum.reduce_while(run_ids, :ok, fn run_id, :ok ->
      case gh_fun.(["run", "rerun", run_id, "--failed", "--repo", repo]) do
        {_out, 0} -> {:cont, :ok}
        {out, _} -> {:halt, {:error, String.trim(out)}}
      end
    end)
  end

  @doc "The record a recovery leaves in plan metadata."
  @spec record(String.t(), :merge_main | :rerun, [String.t()], DateTime.t()) :: recovery()
  def record(head, action, run_ids, now \\ DateTime.utc_now()) do
    %{"head" => head, "action" => Atom.to_string(action), "run_ids" => run_ids, "at" => DateTime.to_iso8601(now)}
  end

  @doc "What Symphony says on the issue after it recovers."
  @spec note(String.t(), :merge_main | :rerun, String.t(), String.t()) :: String.t()
  def note(pr_url, :merge_main, reason, head) do
    "**Symphony merged `main` into the branch instead of dispatching Fix CI.** CI on [the PR](#{pr_url}) " <>
      "was red at `#{short(head)}`: #{reason}. The next CI run on the merged head decides what comes next."
  end

  def note(pr_url, :rerun, reason, head) do
    "**Symphony re-ran the failed CI jobs once instead of dispatching Fix CI.** CI on [the PR](#{pr_url}) " <>
      "was red at `#{short(head)}`: #{reason}. If the re-run fails again on this head, Fix CI runs."
  end

  # --- In flight ---------------------------------------------------------------

  defp in_flight(ctx, now) do
    Enum.find_value(ctx.on_head, :none, fn rec ->
      case Map.get(rec, "action") do
        "rerun" -> rerun_in_flight(ctx, Map.get(rec, "run_ids", []))
        "merge_main" -> merge_in_flight(rec, now)
        _ -> nil
      end
    end)
  end

  defp rerun_in_flight(ctx, run_ids) do
    if Enum.any?(run_ids, &(run_status(ctx, &1) not in ["completed", :unknown])) do
      {:wait, "the re-run of the failed jobs is still running"}
    end
  end

  # The PR head is still the one the merge was asked on, so GitHub has not moved it yet.
  defp merge_in_flight(rec, now) do
    with at when is_binary(at) <- Map.get(rec, "at"),
         {:ok, at, _} <- DateTime.from_iso8601(at),
         true <- DateTime.diff(now, at) < @merge_settle_seconds do
      {:wait, "`main` was merged into the branch and the PR head has not moved yet"}
    else
      _ -> nil
    end
  end

  # --- The failed jobs ---------------------------------------------------------

  # A check that is not a GitHub Actions job cannot be re-run from here.
  defp actions_jobs(failing) do
    jobs =
      Enum.map(failing, fn check ->
        case Regex.run(@job_link, Map.get(check, "link") || "") do
          [_, run_id, job_id] -> %{name: Map.get(check, "name", "check"), run_id: run_id, job_id: job_id}
          _ -> {:not_actions, Map.get(check, "name", "check")}
        end
      end)

    case Enum.find(jobs, &match?({:not_actions, _}, &1)) do
      {:not_actions, name} -> {:fix_ci, "`#{name}` is not a GitHub Actions job, so it cannot be re-run"}
      nil -> {:ok, jobs}
    end
  end

  # `gh run rerun --failed` refuses a run that is still going, and a run still going
  # has not given its verdict. Wait for it.
  defp finished_runs(ctx, jobs) do
    run_ids = jobs |> Enum.map(& &1.run_id) |> Enum.uniq()

    if Enum.any?(run_ids, &(run_status(ctx, &1) not in ["completed", :unknown])) do
      {:wait, "a failed job's workflow run is still running"}
    else
      {:ok, run_ids}
    end
  end

  defp run_status(ctx, run_id) do
    case ctx.gh.(["run", "view", run_id, "--repo", ctx.repo, "--json", "status", "-q", ".status"]) do
      {out, 0} -> String.trim(out)
      _ -> :unknown
    end
  end

  # --- Classification ----------------------------------------------------------

  defp in_diff(_ctx, _job, []), do: nil

  defp in_diff(ctx, job, diff) do
    case job_log(ctx, job) do
      nil ->
        nil

      log ->
        case Enum.find(failure_paths(log), &touched?(&1, diff)) do
          nil -> nil
          path -> {job.name, path}
        end
    end
  end

  defp describe_job(ctx, job) do
    case failed_step(ctx, job) do
      {:setup, step} -> "`#{job.name}` failed in the setup step `#{step}`, before its tests ran"
      {:work, step} -> "`#{job.name}` failed in `#{step}` and names no file of the diff"
      :none -> "`#{job.name}` failed before any step ran"
      :unknown -> "`#{job.name}` names no file of the diff"
    end
  end

  @doc """
  Classify a job from the REST `jobs/<id>` payload: `{:setup, step}` when its first
  failed step is a setup step, `{:work, step}` otherwise, `:none` with no failed step.
  """
  @spec classify_steps(map()) :: {:setup | :work, String.t()} | :none
  def classify_steps(%{"steps" => steps}) when is_list(steps) do
    case Enum.find(steps, &(Map.get(&1, "conclusion") == "failure")) do
      nil -> :none
      %{"name" => name} -> if Regex.match?(@setup_step, name), do: {:setup, name}, else: {:work, name}
    end
  end

  def classify_steps(_), do: :none

  defp failed_step(ctx, job) do
    with {out, 0} <- ctx.gh.(["api", "repos/#{ctx.repo}/actions/jobs/#{job.job_id}"]),
         {:ok, payload} <- Jason.decode(out) do
      classify_steps(payload)
    else
      _ -> :unknown
    end
  end

  defp job_log(ctx, job) do
    case ctx.gh.(["run", "view", "--job", job.job_id, "--repo", ctx.repo, "--log-failed"]) do
      {out, 0} -> out
      _ -> nil
    end
  end

  @gh_prefix ~r/^[^\t\n]*\t[^\t\n]*\t\d{4}-\d\d-\d\dT[\d:.]+Z ?/m
  @ansi ~r/\e\[[0-9;]*m/
  @exunit_failure ~r/^\s*\d+\) test .*\n\s*(\S+\.exs?):\d+/m
  @diagnostic ~r/(?:└─|\*\* \(\w+Error\)|┃)\s*(\S+\.(?:exs?|heex|js|ts|tsx)):\d+/
  @unformatted ~r/^\s+\* (\S+\.(?:exs?|heex))\s*$/m

  @doc """
  The file paths a job log names as failure locations: ExUnit failure blocks,
  compiler and Credo diagnostics, and `mix format --check-formatted`'s list. A path
  that only appears in ordinary output (a timing table, a shard list) is not one.
  `gh run view --log` prefixes every line with job, step and timestamp; those go first.
  """
  @spec failure_paths(String.t()) :: [String.t()]
  def failure_paths(log) do
    text = log |> String.replace(@gh_prefix, "") |> String.replace(@ansi, "")

    [@exunit_failure, @diagnostic, @unformatted]
    |> Enum.flat_map(&Regex.scan(&1, text, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "Whether a log path names a diff file. CI prints paths from its own checkout root."
  @spec touched?(String.t(), [String.t()]) :: boolean()
  def touched?(path, diff) do
    Enum.any?(diff, fn file -> path == file or String.ends_with?(path, "/" <> file) end)
  end

  defp diff_files(ctx) do
    case ctx.gh.(["pr", "diff", ctx.number, "--repo", ctx.repo, "--name-only"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  # --- Does main carry the fix -------------------------------------------------

  # Main carries a fix when it has moved past the head, every failed check is green on
  # main's head, and there is a reason to think main changed the verdict: the check was
  # red on the merge base (the advisory that failed every PR, GEA-10490), or a re-run
  # on this head already failed. A failure main is merely green on is a flake, and
  # merging main for a flake moves the head: CI runs in full, not only the failed
  # jobs, and CodeRabbit is asked to review again.
  defp main_carries_fix?(ctx, rerun_spent?) do
    with {:ok, base, merge_base, ahead} <- compare(ctx),
         true <- ahead > 0,
         true <- green_on?(ctx, base) do
      rerun_spent? or red_on?(ctx, merge_base)
    else
      _ -> false
    end
  end

  defp compare(ctx) do
    with {base, 0} <- ctx.gh.(["api", "repos/#{ctx.repo}", "-q", ".default_branch"]),
         base = String.trim(base),
         {out, 0} <- ctx.gh.(["api", "repos/#{ctx.repo}/compare/#{ctx.head}...#{base}"]),
         {:ok, %{"ahead_by" => ahead, "merge_base_commit" => %{"sha" => merge_base}}} <- Jason.decode(out) do
      {:ok, base, merge_base, ahead}
    else
      _ -> :error
    end
  end

  defp green_on?(ctx, ref) do
    conclusions = check_conclusions(ctx, ref)
    Enum.all?(ctx.names, &(Map.get(conclusions, &1) == "success"))
  end

  defp red_on?(ctx, ref) do
    conclusions = check_conclusions(ctx, ref)
    Enum.any?(ctx.names, &(Map.get(conclusions, &1) in ["failure", "timed_out"]))
  end

  defp check_conclusions(ctx, ref) do
    with {out, 0} <- ctx.gh.(["api", "repos/#{ctx.repo}/commits/#{ref}/check-runs?per_page=100"]),
         {:ok, %{"check_runs" => runs}} <- Jason.decode(out) do
      # A re-run leaves each attempt as its own check run; the newest has the highest id.
      runs
      |> Enum.sort_by(&(&1["id"] || 0), :desc)
      |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run["name"], run["conclusion"]) end)
    else
      _ -> %{}
    end
  end

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(_), do: "?"
end
