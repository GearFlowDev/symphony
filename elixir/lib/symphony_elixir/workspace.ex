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
  @hook_pid_preamble "printf '%s' \"$$\" > \"$SYMPHONY_HOOK_PIDFILE\" 2>/dev/null || true\n"

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
            # Release any claimed pool slot before removing the workspace
            release_pool_slot(workspace)
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
            release_pool_slot(workspace)
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

  @spec release_pool_slot(Path.t()) :: :ok
  def release_pool_slot(workspace) do
    slot_file = Path.join(workspace, ".symphony_slot")

    if File.exists?(slot_file) do
      case Config.workspace_hooks()[:before_remove] do
        nil ->
          release_via_default_script(workspace)

        command ->
          # A configured before_remove hook owns slot release. Running the
          # bundled slot-release.sh here instead would bypass the machine's
          # slot protocol (e.g. registry leases on gf_engineering machines)
          # and leave its claim records behind.
          Logger.info("Releasing pool slot via before_remove hook for workspace=#{workspace}")

          run_hook(
            command,
            workspace,
            %{issue_id: nil, issue_identifier: Path.basename(workspace)},
            "before_remove"
          )
          |> ignore_hook_failure()
      end
    else
      # No marker, but a registry lease for this workspace may still be open
      # (e.g. the marker was cleaned but release didn't finish). Release it
      # synchronously so a manual redispatch can reclaim the slot now instead of
      # waiting for the next poll-cycle reaper.
      release_registry_lease_for_workspace(workspace)
    end

    :ok
  end

  # Synchronously release any Symphony-owned lease whose recorded workspace is
  # this one. Mirrors the per-poll reaper but targets a single workspace, for
  # the manual-redispatch path that needs the slot freed immediately.
  defp release_registry_lease_for_workspace(workspace) do
    expanded = Path.expand(workspace)

    for {slot_name, lease} <- registry_leases(),
        symphony_owned?(lease),
        ws = to_string(lease["workspace"] || ""),
        ws != "",
        Path.expand(ws) == expanded do
      Logger.info("Releasing registry lease #{slot_name} for workspace=#{workspace} (no marker; synchronous release)")
      release_registry_lease(slot_name)
    end

    :ok
  end

  # Grace window so a freshly-claimed lease (written by before_run just before
  # the run registers) is never reaped out from under a starting agent. The
  # primary safety is the not-running check below; this is extra margin.
  @orphan_lease_grace_seconds 120

  defp release_via_default_script(workspace) do
    release_script = scripts_path("slot-release.sh")

    if File.exists?(release_script) do
      Logger.info("Releasing pool slot for workspace=#{workspace}")

      case System.cmd("bash", [release_script, workspace], stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("Pool slot released: #{String.trim(output)}")

        {output, status} ->
          Logger.warning("Pool slot release failed status=#{status}: #{String.trim(output)}")
      end
    end
  end

  @doc """
  Release registry slot leases that no longer back a running issue — the
  orchestrator's per-poll safety net for slots whose run ended without its
  before_remove release firing (e.g. an agent killed on a stall timeout).

  `active_identifiers` is the set of issue identifiers currently running. A lease
  is reaped only when ALL of these hold:

    * Symphony owns it (`owner == "symphony"`). A lease held by an interactive
      human session is NEVER touched — `release_registry_lease/1` does a
      `git reset --hard`, which on a shared machine would wipe a teammate's
      uncommitted work. This owner guard is the primary safety.
    * It sits on a Symphony-designated slot (when `SYMPHONY_PLATFORM_SLOTS` /
      `SYMPHONY_PROCUREMENT_SLOTS` are set — the same designation
      slot-claim-registry.sh honors). Defense in depth on top of the owner guard.
    * Its issue is NOT running — so a re-dispatched issue, already back in
      `running`, is never clobbered — and it was claimed more than the grace
      window ago.

  The freed slot is reset to origin/main so it is immediately reclaimable.
  Best-effort; never raises. Returns the reaped slots.
  """
  @spec reap_stale_pool_locks([String.t()]) :: [String.t()]
  def reap_stale_pool_locks(active_identifiers) when is_list(active_identifiers) do
    active = MapSet.new(active_identifiers)
    now = DateTime.utc_now()

    for {slot_name, lease} <- registry_leases(), reduce: [] do
      reaped ->
        issue = to_string(lease["linear_issue"] || "")

        if symphony_owned?(lease) and eligible_slot?(slot_name) and
             issue != "" and not MapSet.member?(active, issue) and
             lease_claimed_older_than?(lease["claimed"], now, @orphan_lease_grace_seconds) do
          Logger.info("Reaping orphaned slot lease #{slot_name}: issue #{issue} is not running")
          release_registry_lease(slot_name)
          [slot_name | reaped]
        else
          reaped
        end
    end
  rescue
    error ->
      Logger.warning("Orphan lease reap failed: #{Exception.message(error)}")
      []
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

  # [{slot_name, lease_map}] for each symphony slot lease in the registry.
  defp registry_leases do
    case local_dev_dir() do
      ld when is_binary(ld) ->
        dir = Path.join(ld, "registry")

        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&Regex.match?(~r/^gf_(?:platform|procurement)-slot\d+\.json$/, &1))
            |> Enum.flat_map(fn file ->
              with {:ok, content} <- File.read(Path.join(dir, file)),
                   {:ok, lease} <- Jason.decode(content) do
                [{String.replace_suffix(file, ".json", ""), lease}]
              else
                _ -> []
              end
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # The reaper only ever touches leases Symphony itself wrote. An interactive
  # human session's lease (any other owner) is off limits — the per-poll
  # `git reset --hard` in release_registry_lease/1 would otherwise wipe a
  # teammate's uncommitted work on a shared machine.
  # A lease is Symphony's if it carries the upstream owner marker ("symphony") OR
  # the orchestrator's conversation_id stamp. The local-dev slot-claim variant sets
  # owner to the tmux session (e.g. "cc-symphony") for liveness and stamps
  # conversation_id="symphony-orchestrator"; without the second clause the reaper
  # never recognises those leases and they leak (the issue completes but the slot
  # stays held).
  defp symphony_owned?(lease),
    do: lease["owner"] == "symphony" or lease["conversation_id"] == "symphony-orchestrator"

  # When the Symphony-eligible slot set is configured (SYMPHONY_PLATFORM_SLOTS /
  # SYMPHONY_PROCUREMENT_SLOTS — space-separated slot numbers, the same
  # designation slot-claim-registry.sh honors), confine reaping to those slots.
  # An unconfigured repo falls back to the owner guard alone.
  defp eligible_slot?(slot_name) do
    case Regex.run(~r/^gf_(platform|procurement)-slot(\d+)$/, slot_name) do
      [_, repo, num] ->
        case eligible_slot_numbers(repo) do
          [] -> true
          nums -> num in nums
        end

      _ ->
        false
    end
  end

  defp eligible_slot_numbers(repo) do
    case System.get_env("SYMPHONY_#{String.upcase(repo)}_SLOTS") do
      v when is_binary(v) and v != "" -> String.split(v, ~r/\s+/, trim: true)
      _ -> []
    end
  end

  # Reset a slot's working copy to origin/main, then free its registry lease —
  # but ONLY if the reset fully succeeded. Freeing the lease first (the old
  # behavior) made a slot claimable while it could still hold the previous run's
  # branch or a dirty worktree, so the next dispatch inherited contaminated
  # state. slot_name e.g. "gf_procurement-slot5".
  defp release_registry_lease(slot_name) do
    case local_dev_dir() do
      ld when is_binary(ld) ->
        slot_dir = Path.join(ld, slot_name)

        if reset_slot_to_main?(slot_dir) do
          File.rm(Path.join([ld, "registry", "#{slot_name}.json"]))
        else
          Logger.warning("Leaving lease #{slot_name} in place: reset failed, so the slot is not safe to reclaim yet")
        end

      _ ->
        :ok
    end

    :ok
  end

  # True only when the slot is clean origin/main afterward. A missing working
  # copy is vacuously clean (nothing to contaminate); otherwise every git step
  # must exit 0.
  defp reset_slot_to_main?(slot_dir) do
    if File.dir?(slot_dir) do
      [
        ["-C", slot_dir, "checkout", "--", "."],
        ["-C", slot_dir, "checkout", "main"],
        ["-C", slot_dir, "reset", "--hard", "origin/main"]
      ]
      |> Enum.reduce(true, fn args, ok ->
        case System.cmd("git", args, stderr_to_stdout: true) do
          {_, 0} ->
            ok

          {out, code} ->
            Logger.warning("git #{Enum.join(args, " ")} failed (#{code}) in #{slot_dir}: #{String.trim(out)}")
            false
        end
      end)
    else
      true
    end
  end

  defp lease_claimed_older_than?(claimed, now, grace) when is_binary(claimed) do
    case DateTime.from_iso8601(claimed) do
      {:ok, dt, _} -> DateTime.diff(now, dt) > grace
      _ -> true
    end
  end

  defp lease_claimed_older_than?(_claimed, _now, _grace), do: true

  @spec release_pool_slot_for_issue(String.t()) :: :ok
  def release_pool_slot_for_issue(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = workspace_path_for_issue(safe_id)
    release_pool_slot(workspace)
  end

  def release_pool_slot_for_issue(_identifier), do: :ok

  @doc """
  `{slot_working_copy_dir, branch}` for the slot currently leased to `identifier`,
  or nil. Read straight from the registry lease — reliable even when the scratch
  workspace's `.symphony_slot` is gone between dispatches, or the slot tree is
  parked on `main`. Used to act on the issue's PR from a real repo checkout.
  """
  @spec slot_lease_for_issue(String.t() | nil) :: {Path.t(), String.t()} | nil
  def slot_lease_for_issue(identifier) when is_binary(identifier) do
    ld = local_dev_dir()

    Enum.find_value(registry_leases(), fn {slot_name, lease} ->
      if is_binary(ld) and to_string(lease["linear_issue"]) == identifier do
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

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    # Run after_create hook if either:
    # 1. The workspace was just created, or
    # 2. The workspace exists but has no .symphony_slot (slot not claimed yet)
    needs_hook = created? or not File.exists?(Path.join(workspace, ".symphony_slot"))

    case needs_hook do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
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
        System.cmd("sh", ["-lc", @hook_pid_preamble <> command],
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
    descendants = Enum.flat_map(child_pids(pid), &kill_process_tree/1)
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    descendants ++ [pid]
  end

  defp kill_process_tree(_pid), do: []

  defp child_pids(pid) when is_integer(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(~r/\s+/, trim: true)
        |> Enum.flat_map(fn token ->
          case Integer.parse(token) do
            {child, ""} -> [child]
            _ -> []
          end
        end)

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
    repo =
      repo_from_pr_url(issue_context[:pr_url]) ||
        cond do
          Enum.any?(labels, &label_matches_repo?(&1, "2.0")) -> "platform"
          Enum.any?(labels, &label_matches_repo?(&1, "3.0")) -> "procurement"
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
    case Regex.run(~r{github\.com/[^/]+/(gf_platform|gf_procurement)/pull/}, url) do
      [_, "gf_platform"] -> "platform"
      [_, "gf_procurement"] -> "procurement"
      _ -> nil
    end
  end

  defp repo_from_pr_url(_), do: nil

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  @doc false
  def scripts_path(script_name) do
    Application.app_dir(:symphony_elixir, Path.join("priv/scripts", script_name))
  end
end
