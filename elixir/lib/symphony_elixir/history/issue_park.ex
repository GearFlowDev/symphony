defmodule SymphonyElixir.History.IssuePark do
  @moduledoc """
  The moment Symphony parked an issue for a person. A park ends a release: when a
  person moves the issue back out of Shaping, the work restarts, and tester
  verdicts recorded before the park no longer gate it (GEA-10531).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "issue_parks" do
    field(:issue_identifier, :string)
    field(:reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:issue_identifier, :reason])
    |> validate_required([:issue_identifier])
  end
end
