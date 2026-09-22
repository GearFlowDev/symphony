defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the agent runtime — the orchestrator and the agent tasks it owns — in
  the current BEAM node.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.AgentRuntimeSupervisor.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = SymphonyElixir.Repo.configure()
    if reap_orphans?(), do: reap_orphan_tmux_sessions()

    children = [
      SymphonyElixir.Repo,
      SymphonyElixir.Repo.Migrator,
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.AgentRuntimeSupervisor,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  # False under :test (config/config.exs): a test BEAM must never reap the live
  # orchestrator's sessions or leases. The orchestrator's per-poll reapers
  # honour the same flag.
  defp reap_orphans?, do: Application.get_env(:symphony_elixir, :reap_orphans, true)

  # Clean up tmux sessions leaked by a previous run that crashed before its
  # AgentRunner could stop them. Never let this block or fail startup.
  defp reap_orphan_tmux_sessions do
    case SymphonyElixir.Claude.TmuxCLI.reap_orphan_sessions() do
      [] -> :ok
      reaped -> Logger.info("Reaped #{length(reaped)} orphaned Claude tmux session(s): #{inspect(reaped)}")
    end
  rescue
    error -> Logger.warning("Orphan tmux session reap failed: #{Exception.message(error)}")
  end
end
