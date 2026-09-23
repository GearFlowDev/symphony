defmodule SymphonyElixir.Planning.Dispatch do
  @moduledoc """
  One worker run against a slice of a `Plan`.

  Recorded once at dispatch time and updated when the Grader returns its
  verdict. The grade JSON has the shape:

      %{
        "verdict" => "approve" | "request_changes" | "blocked",
        "rationale" => "one-paragraph summary",
        "rows" => [
          %{"id" => "R1", "state" => "done", "note" => "..."},
          %{"id" => "R3", "state" => "partial", "note" => "missing X"}
        ]
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Planning.Plan

  @primary_key {:id, :binary_id, autogenerate: true}

  @roles ~w(implement test regrade)

  schema "plan_dispatches" do
    belongs_to(:plan, Plan, type: :binary_id)
    field(:run_id, :binary_id)
    field(:slot_name, :string)
    field(:role, :string, default: "implement")
    field(:assigned_rows_json, :map, default: %{})
    field(:grade_json, :map)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required ~w(plan_id role)a
  @optional ~w(run_id slot_name assigned_rows_json grade_json started_at finished_at)a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:role, @roles)
  end

  @spec grade_changeset(t(), map()) :: Ecto.Changeset.t()
  def grade_changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, [:grade_json, :finished_at])
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles
end
