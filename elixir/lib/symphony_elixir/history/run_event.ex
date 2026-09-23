defmodule SymphonyElixir.History.RunEvent do
  @moduledoc """
  Schema for events within a run — phase changes, retries, PR detection, etc.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "run_events" do
    field(:run_id, :binary_id)
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:timestamp, :utc_datetime_usec)
  end

  @required_fields ~w(run_id event_type timestamp)a
  @optional_fields ~w(payload)a

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
