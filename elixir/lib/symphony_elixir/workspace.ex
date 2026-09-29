defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])
  @hook_pid_file_prefix "symphony-hook-"
  # Recorded before the hook body runs, so an abandoned hook can be killed WITH
  # its children. `$$` is this shell; every process the hook starts hangs below
  # it, and closing the port only ever reaches the shell itself.
  @hook_pid_preamble ~s(printf '%s' "$$" > "$SYMPHONY_HOOK_PIDFILE" 2>/dev/null || true\n)
  # A shell running `-c` will `exec` its LAST command and replace itself, which
  # loses both the recorded pid's identity (`still_our_hook?/1` reads the
  # command line for the marker) and the parent the children hang from. A
  # trailing builtin leaves the shell in place.
  @hook_pid_epilogue "\nexit $?"

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- run_after_create_or_clean_up(workspace, issue_context, created?) do
        # Always hand back the symphony workspace — never a slot directory.
        # Resolving a leftover .symphony_slot to its slot dir here (pre-claim)
        # made interrupted-run retries pass a SLOT DIR as $WORKSPACE to the
        # before_run hook, whose re-entry check then failed and claimed a
        # second slot while writing a contract into the first slot's tree —
        # the root of the double-booked-slot incidents (GEA-4394/GEA-3370).
        # The hook re-claims idempotently from the contract in this workspace,
        # and agents cd into the slot via .symphony_slot themselves.
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            # `before_remove` owns slot release, so this one run releases the
            # pool slot too. Calling `release_pool_slot/1` first ran the same
            # hook twice on every removal (GEA-10251).
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @doc """
  Removes a workspace by the path the caller RECORDED when it was created.

  `remove_issue_workspaces/1` recomputes the path from the live
  `workspace.root`, so a config edit or reload between create and cleanup sends
  the removal at a directory that was never this issue's — and leaves the real
  one behind, still holding its pool slot. A recorded path validates against its
  own parent instead of against the current root (upstream 7cf29df).
  """
  @spec remove_recorded(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace) when is_binary(workspace) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}, ""}

      Path.type(workspace) != :absolute ->
        {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}

      not File.exists?(workspace) ->
        File.rm_rf(workspace)

      true ->
        case validate_workspace_path(workspace, Path.dirname(workspace)) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end
    end
  end

  def remove_recorded(workspace) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  @doc "The workspace directory this issue identifier resolves to under the current root."
  @spec path_for_issue(String.t() | nil) :: Path.t() | nil
  def path_for_issue(identifier) when is_binary(identifier) do
    identifier
    |> safe_identifier()
    |> workspace_path_for_issue()
  end

  def path_for_issue(_identifier), do: nil

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  @doc """
  Releases the pool slot a workspace's `.symphony_slot` names, through the
  `before_remove` hook and nothing else.

  The harness owns slots: `lease release` decides whether a lease is ours, and
  `slot-status` / `lease claim --reclaim` handle a lease nobody released. The
  fork used to reset slot trees and delete lease files itself, which bypassed
  that ownership check and could reset a tree holding unmerged work
  (GEA-10251). With no marker or no hook there is nothing to release here.
  """
  @spec release_pool_slot(Path.t()) :: :ok
  def release_pool_slot(workspace) do
    if File.exists?(Path.join(workspace, ".symphony_slot")) do
      maybe_run_before_remove_hook(workspace)
    end

    :ok
  end

  # local-dev dir that holds registry/ and the slot working copies.
  defp local_dev_dir do
    case System.get_env("GEARFLOW_WORKSPACE") do
      ws when is_binary(ws) and ws != "" ->
        Path.join(ws, "local-dev")

      _ ->
        # Fallback: SYMPHONY_SCRIPTS is <local-dev>/symphony/elixir/priv/scripts/
        case System.get_env("SYMPHONY_SCRIPTS") do
          s when is_binary(s) and s != "" -> Path.expand(Path.join(s, "../../../.."))
          _ -> nil
        end
    end
  end

  # [{slot_name, lease_map}] for each slot lease in the registry, whatever the
  # repo: `before_run` provisions a slot of any repo `provision-slot.sh` knows.
  defp registry_leases do
    case local_dev_dir() do
      ld when is_binary(ld) ->
        ld |> Path.join("registry") |> read_registry_leases()

      _ ->
        []
    end
  end

  defp read_registry_leases(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(~r/^[A-Za-z0-9_.-]+-slot\d+\.json$/, &1))
        |> Enum.sort()
        |> Enum.flat_map(&read_registry_lease(dir, &1))

      _ ->
        []
    end
  end

  defp read_registry_lease(dir, file) do
    with {:ok, content} <- File.read(Path.join(dir, file)),
         {:ok, lease} when is_map(lease) <- Jason.decode(content) do
      [{String.replace_suffix(file, ".json", ""), lease}]
    else
      _ -> []
    end
  end

  @spec release_pool_slot_for_issue(String.t()) :: :ok
  def release_pool_slot_for_issue(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = workspace_path_for_issue(safe_id)
    release_pool_slot(workspace)
  end

  def release_pool_slot_for_issue(_identifier), do: :ok

  @doc """
  `{slot_working_copy_dir, branch}` for the slot Symphony leased to `identifier`,
  or nil. Read straight from the registry lease — reliable even when the scratch
  workspace's `.symphony_slot` is gone between dispatches, or the slot tree is
  parked on `main`. Used to act on the issue's PR from a real repo checkout.

  Only Symphony's own lease counts: `before_run` claims it under the session id
  `symphony-<issue>`. The registry holds every repo's slots, so a person's lease
  or another repo's slot can name the same issue, and pushing or opening a PR
  from that checkout would act in the wrong tree.
  """
  @spec slot_lease_for_issue(String.t() | nil) :: {Path.t(), String.t()} | nil
  def slot_lease_for_issue(identifier) when is_binary(identifier) do
    ld = local_dev_dir()

    Enum.find_value(registry_leases(), fn {slot_name, lease} ->
      if is_binary(ld) and to_string(lease["linear_issue"]) == identifier and
           lease["conversation_id"] == "symphony-" <> identifier do
        {Path.join(ld, slot_name), to_string(lease["branch"])}
      end
    end)
  end

  def slot_lease_for_issue(_), do: nil

  @doc "Scratch workspace path for an issue identifier (resolve the slot via `.symphony_slot`)."
  @spec scratch_path(String.t() | nil) :: Path.t() | nil
  def scratch_path(identifier) when is_binary(identifier),
    do: workspace_path_for_issue(safe_identifier(identifier))

  def scratch_path(_), do: nil

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  # A failed `after_create` leaves a directory that LOOKS provisioned: the next
  # attempt finds `File.dir?/1` true, skips creation, and inherits whatever the
  # half-run hook wrote. Remove what THIS call created so the retry bootstraps
  # from nothing; a workspace that already existed is left alone (upstream
  # cbd2158).
  defp run_after_create_or_clean_up(workspace, issue_context, created?) do
    case maybe_run_after_create_hook(workspace, issue_context, created?) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        cleanup_failed_new_workspace(workspace, created?)
        error
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false), do: :ok

  defp cleanup_failed_new_workspace(workspace, true) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  end

  # `after_create` runs once, when this call created the directory (SPEC.md § after_create).
  # It used to re-run on any reuse without a `.symphony_slot`, because the slot claim lived in
  # this hook (d4c68db). The claim now lives in `before_run`, which runs every attempt and
  # re-claims idempotently, so re-running `after_create` only overwrote a reused workspace.
  defp maybe_run_after_create_hook(_workspace, _issue_context, false), do: :ok

  defp maybe_run_after_create_hook(workspace, issue_context, true) do
    case Config.workspace_hooks()[:after_create] do
      nil -> :ok
      command -> run_hook(command, workspace, issue_context, "after_create")
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    pid_file = hook_pid_file(workspace)
    env = [{"SYMPHONY_HOOK_PIDFILE", pid_file} | hook_env(issue_context)]

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", @hook_pid_preamble <> command <> @hook_pid_epilogue],
          cd: workspace,
          stderr_to_stdout: true,
          env: env
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        File.rm(pid_file)
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        # Shutting the task down closes the port, which kills `sh` and NOTHING
        # BELOW IT. A provisioning `before_run` spawns its real work as a child,
        # so the abandoned hook kept building a slot while the orchestrator
        # re-dispatched beside it and a second provisioner claimed a second slot
        # for the same issue (first Fly run, GEA-9889, 2026-09-22).
        killed = kill_hook_tree(workspace)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms} killed_pids=#{inspect(killed)}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  @doc """
  Kills a still-running workspace hook and every process it started.

  Returns the OS pids it signalled, newest descendant first. A no-op when the
  workspace records no live hook.
  """
  @spec kill_hook_tree(Path.t()) :: [pos_integer()]
  def kill_hook_tree(workspace) when is_binary(workspace) do
    pid_file = hook_pid_file(workspace)

    with {:ok, contents} <- File.read(pid_file),
         {pid, _rest} <- Integer.parse(String.trim(contents)),
         true <- still_our_hook?(pid) do
      File.rm(pid_file)
      kill_process_tree(pid)
    else
      _ ->
        File.rm(pid_file)
        []
    end
  end

  def kill_hook_tree(_workspace), do: []

  # A pid file outlives the shell that wrote it, and the box recycles pids.
  # Kill only a process whose command line still carries the hook preamble —
  # otherwise a stale file aims `kill -KILL` at whatever now holds that number.
  defp still_our_hook?(pid) when is_integer(pid) and pid > 1 do
    case System.cmd("ps", ["-o", "args=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, "SYMPHONY_HOOK_PIDFILE")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp still_our_hook?(_pid), do: false

  defp kill_process_tree(pid) when is_integer(pid) and pid > 1 do
    # STOP before enumerating. A live shell forks the next command while we are
    # walking its children, and that fork is then never seen or killed — which
    # is the whole failure being fixed here, one level down.
    signal(pid, "-STOP")
    descendants = Enum.flat_map(child_pids(pid), &kill_process_tree/1)
    signal(pid, "-KILL")
    descendants ++ [pid]
  end

  defp kill_process_tree(_pid), do: []

  defp signal(pid, flag) when is_integer(pid) do
    System.cmd("kill", [flag, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp child_pids(pid) when is_integer(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(~r/\s+/, trim: true)
        |> Enum.flat_map(&parse_pid_token/1)

      _ ->
        []
    end
  rescue
    # `pgrep` is absent on a minimal image; an unkillable tree is worse news
    # than a missing one, so say so rather than failing the hook.
    error ->
      Logger.warning("Cannot enumerate hook child processes pid=#{pid}: #{Exception.message(error)}")
      []
  end

  defp parse_pid_token(token) do
    case Integer.parse(token) do
      {child, ""} -> [child]
      _ -> []
    end
  end

  # Outside the workspace on purpose. A bootstrap `after_create` hook is often
  # `git clone <url> .`, which refuses to run in a directory that is not empty —
  # so a pid file written INTO the workspace breaks the very hook it exists to
  # supervise. Keyed by the workspace path so it is stable across the hook's
  # lifetime and unique per workspace.
  defp hook_pid_file(workspace) when is_binary(workspace) do
    digest =
      :sha256
      |> :crypto.hash(Path.expand(workspace))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 32)

    Path.join(System.tmp_dir!(), @hook_pid_file_prefix <> digest <> ".pid")
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  # Exit 75 (EX_TEMPFAIL): the hook can't proceed right now — e.g. no free pool
  # slot (the pool is shared with interactive sessions). Not a failure: signal
  # the caller to back off and retry quietly instead of crashing the run.
  defp handle_hook_command_result({output, 75}, _workspace, issue_context, hook_name) do
    Logger.info(
      "Workspace hook signalled no capacity hook=#{hook_name} #{issue_log_context(issue_context)}: " <>
        String.trim(sanitize_hook_output_for_log(output))
    )

    {:error, :hook_no_capacity}
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 4_096) do
    binary_output = IO.iodata_to_binary(output)
    size = byte_size(binary_output)

    case size <= max_bytes do
      true ->
        binary_output

      false ->
        # Show the tail — the actual error is always at the end
        "... (#{size} bytes, showing last #{max_bytes})\n" <>
          binary_part(binary_output, size - max_bytes, max_bytes)
    end
  end

  @doc """
  True when `path` is inside a local-dev pool slot (`$GEARFLOW_WORKSPACE/local-dev/…`).

  On local-dev machines the agent runs inside a claimed pool slot under
  `$GEARFLOW_WORKSPACE/local-dev/`, not the standard `~/Documents/Gearflow`
  pool root — so the cwd guardrails must accept it too. Returns false when
  `GEARFLOW_WORKSPACE` is unset (standard deployments are unaffected).
  """
  @spec local_dev_slot?(String.t()) :: boolean()
  def local_dev_slot?(path) when is_binary(path) do
    case System.get_env("GEARFLOW_WORKSPACE") do
      ws when is_binary(ws) and ws != "" ->
        String.starts_with?(Path.expand(path), Path.expand(Path.join(ws, "local-dev")) <> "/")

      _ ->
        false
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    validate_workspace_path(workspace, Config.workspace_root())
  end

  defp validate_workspace_path(workspace, root) when is_binary(workspace) and is_binary(root) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(root)
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier, labels: labels, branch_name: branch_name} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: labels || [],
      branch_name: branch_name,
      pr_url: Map.get(issue, :pr_url)
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier, labels: labels}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: labels || [],
      branch_name: nil
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: [],
      branch_name: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      labels: [],
      branch_name: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      labels: [],
      branch_name: nil
    }
  end

  defp hook_env(issue_context) do
    labels = Map.get(issue_context, :labels, [])

    env =
      System.get_env()
      |> Map.put("SYMPHONY_ISSUE_ID", issue_context[:issue_id] || "")
      |> Map.put("SYMPHONY_ISSUE_IDENTIFIER", issue_context[:issue_identifier] || "")
      |> Map.put("SYMPHONY_ISSUE_LABELS", Enum.join(labels, ","))
      |> Map.put("SYMPHONY_BRANCH_NAME", issue_context[:branch_name] || "")

    # Routing: the issue's resolved PR is authoritative for which repo's slot
    # to lease — labels are a guess and can be wrong (GEA-5247: `3.0` label on
    # gf_platform work leased a procurement slot; the worker could only refuse).
    # The value is the raw repository name (`gf_platform`, `symphony`, …), and
    # the `before_run` hook maps it to a slot. Only the hook knows which repos
    # this machine can provision (GEA-10251).
    repo =
      repo_from_pr_url(issue_context[:pr_url]) ||
        cond do
          Enum.any?(labels, &label_matches_repo?(&1, "2.0")) -> "gf_platform"
          Enum.any?(labels, &label_matches_repo?(&1, "3.0")) -> "gf_procurement"
          true -> ""
        end

    env
    |> Map.put("SYMPHONY_REPO", repo)
    |> Map.put("SYMPHONY_ROOT", Application.app_dir(:symphony_elixir))
    |> Map.put("SYMPHONY_SCRIPTS", scripts_path("") <> "/")
    |> Map.to_list()
  end

  defp label_matches_repo?(label, prefix) do
    normalized = String.downcase(label)
    normalized == prefix or String.starts_with?(normalized, prefix)
  end

  defp repo_from_pr_url(url) when is_binary(url) do
    case Regex.run(~r{\Ahttps://github\.com/GearFlowDev/([A-Za-z0-9_-][A-Za-z0-9_.-]*)/pull/\d+}i, url) do
      [_, repo] -> repo
      _ -> nil
    end
  end

  defp repo_from_pr_url(_), do: nil

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  @doc false
  @spec scripts_path(String.t()) :: String.t()
  def scripts_path(script_name) do
    Application.app_dir(:symphony_elixir, Path.join("priv/scripts", script_name))
  end
end
