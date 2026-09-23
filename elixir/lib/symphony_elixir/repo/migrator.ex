defmodule SymphonyElixir.Repo.Migrator do
  @moduledoc """
  Runs Ecto migrations on application startup.
  No manual `mix ecto.migrate` needed.
  """

  use GenServer
  require Logger

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    migrate()
    {:ok, :done}
  end

  defp migrate do
    Logger.info("Running Symphony database migrations...")
    Ecto.Migrator.run(SymphonyElixir.Repo, migrations_path(), :up, all: true)
    Logger.info("Symphony database migrations complete.")
  rescue
    error ->
      Logger.warning("Symphony database migration failed: #{Exception.message(error)}")
  end

  defp migrations_path do
    priv_dir =
      case :code.priv_dir(:symphony_elixir) do
        {:error, _} ->
          # Fallback for dev/escript — walk up from this file
          Path.join([__DIR__, "..", "..", "..", "priv"])
          |> Path.expand()

        dir ->
          List.to_string(dir)
      end

    Path.join(priv_dir, "repo/migrations")
  end
end
