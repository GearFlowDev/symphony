defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment_with_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback claim_issue(String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment_with_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_comment_with_id(issue_id, body) do
    adapter().create_comment_with_id(issue_id, body)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    adapter().update_comment(comment_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec claim_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def claim_issue(issue_id, state_name) do
    adapter().claim_issue(issue_id, state_name)
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name) do
    adapter().add_label(issue_id, label_name)
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label_name) do
    adapter().remove_label(issue_id, label_name)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.tracker_kind() do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
