defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the orchestrator together with the agent tasks it dispatches.

  The orchestrator's knowledge of a running agent lives only in its own process
  state, so an orchestrator that restarts comes back believing nothing is
  running while the agent tasks keep editing their slots. `:one_for_all` ties
  the two together: whichever half dies, both are restarted, and the task
  supervisor's exit takes every agent it owned with it.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name = Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)
    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_supervisor_name}, id: task_supervisor_name),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, name: orchestrator_name, task_supervisor: task_supervisor_name},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
