defmodule SymphonyElixir.History.Run do
  @moduledoc """
  Schema for a single orchestrator dispatch — one agent working on one issue.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "runs" do
    # Issue context
    field(:issue_id, :string)
    field(:issue_identifier, :string)
    field(:issue_title, :string)
    field(:issue_priority, :integer)
    field(:issue_labels, {:array, :string}, default: [])

    # Targeting context
    field(:filter_source, :string)
    field(:project_slug, :string)

    # Run lifecycle
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:outcome, :string)
    field(:agent_backend, :string)
    field(:session_id, :string)
    field(:workspace_path, :string)

    # Effort
    field(:turns_used, :integer, default: 0)
    field(:retry_attempt, :integer, default: 0)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:total_tokens, :integer, default: 0)
    field(:wall_clock_ms, :integer)

    # Phase reached
    field(:final_phase, :string)

    # Evaluation
    field(:eval_score, :integer)
    field(:eval_pr_created, :boolean)
    field(:eval_pr_url, :string)
    field(:eval_ci_status, :string)
    field(:eval_files_changed, :integer)
    field(:eval_lines_changed, :integer)
    field(:eval_branch_pushed, :boolean)
    field(:eval_evidence_posted, :boolean)
    field(:eval_workpad_updated, :boolean)
    field(:eval_tests_written, :boolean)

    # Escalation
    field(:escalation_type, :string)
    field(:escalated_at, :utc_datetime_usec)
    field(:needs_human, :boolean, default: false)
    field(:needs_human_message, :string)

    # Error context
    field(:error_message, :string)
    field(:error_category, :string)

    has_many(:events, SymphonyElixir.History.RunEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(issue_id issue_identifier started_at)a
  @optional_fields ~w(
    issue_title issue_priority issue_labels
    filter_source
    finished_at outcome agent_backend session_id workspace_path
    turns_used retry_attempt input_tokens output_tokens total_tokens wall_clock_ms
    final_phase
    eval_score eval_pr_created eval_pr_url eval_ci_status
    eval_files_changed eval_lines_changed eval_branch_pushed
    eval_evidence_posted eval_workpad_updated eval_tests_written
    escalation_type escalated_at needs_human needs_human_message
    error_message error_category
  )a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @spec completion_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def completion_changeset(%__MODULE__{} = run, attrs) do
    run
    |> cast(attrs, @optional_fields)
  end

  @spec evaluation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def evaluation_changeset(%__MODULE__{} = run, attrs) do
    eval_fields = ~w(
      eval_score eval_pr_created eval_pr_url eval_ci_status
      eval_files_changed eval_lines_changed eval_branch_pushed
      eval_evidence_posted eval_workpad_updated eval_tests_written
    )a

    run
    |> cast(attrs, eval_fields)
  end
end
