defmodule SymphonyElixir.Planning.Plan do
  @moduledoc """
  Schema for an orchestrator-owned execution plan for a single Linear issue.

  Replaces the in-repo `WORKPAD.md` audit file. The canonical plan lives in
  this row's `plan_json` map; a mirrored `## Plan` comment on Linear is
  kept in sync via `linear_comment_id`.

  `plan_json` shape:

      %{
        "rows" => [
          %{
            "id" => "R1",
            "description" => "Issues list — column set + sort + filters",
            "touches" => ["lib/gf_web/live/issues_live.ex", "test/.../issues_live_test.exs"],
            "tests" => ["test/.../issues_live_test.exs"],
            "depends_on" => [],
            "state" => "missing",  # missing | partial | done | deferred
            "rationale" => nil
          }
        ],
        "out_of_scope" => [
          # rows the reviewer trimmed; each entry has the same shape plus a
          # `signoff_url` field linking to the Linear/PR comment that approved
          # the trim.
        ]
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w(planning dispatching grading done failed)

  schema "plans" do
    field(:issue_id, :string)
    field(:issue_identifier, :string)
    field(:status, :string, default: "planning")
    field(:plan_json, :map, default: %{})
    field(:linear_comment_id, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required ~w(issue_id issue_identifier)a
  @optional ~w(status plan_json linear_comment_id metadata)a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(plan, attrs) do
    plan
    |> cast(attrs, @optional)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Returns the rows list from `plan_json`, or `[]` if absent."
  @spec rows(t()) :: [map()]
  def rows(%__MODULE__{plan_json: %{"rows" => rows}}) when is_list(rows), do: rows
  def rows(_), do: []

  @doc "Returns the rows whose state is `missing` or `partial`."
  @spec open_rows(t()) :: [map()]
  def open_rows(plan) do
    plan |> rows() |> Enum.filter(&(&1["state"] in ["missing", "partial"]))
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
