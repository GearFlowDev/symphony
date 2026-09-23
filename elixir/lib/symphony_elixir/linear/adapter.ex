defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @create_comment_with_id_mutation """
  mutation SymphonyCreateCommentWithId($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($id: String!, $body: String!) {
    commentUpdate(id: $id, input: {body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @claim_issue_mutation """
  mutation SymphonyClaimIssue($issueId: String!, $stateId: String!, $assigneeId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId, assigneeId: $assigneeId}) {
      success
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAddLabel($issueId: String!, $labelId: String!) {
    issueAddLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  # ONE ROUND TRIP FOR THE ISSUE'S TEAM AND EVERY LABEL THAT WEARS THIS NAME.
  # Label names collide across teams, and a workspace that has two `symphony-working`
  # labels must not have another team's become this box's live-run marker: the caller
  # below prefers the issue's own team, then a workspace-level label with no team.
  # This is the same resolution the agent pool's surface does for `auto-working`.
  @label_lookup_query """
  query SymphonyResolveLabelId($issueId: String!, $name: String!) {
    issue(id: $issueId) {
      team {
        id
      }
    }
    issueLabels(filter: {name: {eqIgnoreCase: $name}}) {
      nodes {
        id
        team {
          id
        }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyViewer {
    viewer {
      id
    }
  }
  """

  @assignee_by_email_query """
  query SymphonyAssigneeByEmail($email: String!) {
    users(filter: {email: {eq: $email}}) {
      nodes {
        id
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_comment_with_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_comment_with_id(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_with_id_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true,
         id when is_binary(id) <- get_in(response, ["data", "commentCreate", "comment", "id"]) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@update_comment_mutation, %{id: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec claim_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def claim_issue(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, assignee_id} <- resolve_assignee_id(),
         {:ok, response} <-
           client_module().graphql(@claim_issue_mutation, %{
             issueId: issue_id,
             stateId: state_id,
             assigneeId: assignee_id
           }),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @doc """
  Put `label_name` on the issue. Idempotent: Linear's `issueAddLabel` on a label the
  issue already carries succeeds and changes nothing, so a re-dispatch of a live run
  does not have to ask first.
  """
  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    mutate_label(@add_label_mutation, "issueAddLabel", issue_id, label_name)
  end

  @doc """
  Take `label_name` off the issue. Idempotent in the same way.
  """
  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    mutate_label(@remove_label_mutation, "issueRemoveLabel", issue_id, label_name)
  end

  defp mutate_label(mutation, field, issue_id, label_name) do
    with {:ok, label_id} <- resolve_label_id(issue_id, label_name),
         {:ok, response} <-
           client_module().graphql(mutation, %{issueId: issue_id, labelId: label_id}),
         true <- get_in(response, ["data", field, "success"]) == true do
      :ok
    else
      false -> {:error, :label_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_update_failed}
    end
  end

  # The issue's own team's label wins; a workspace-level label (no team) is the
  # fallback. Another team's same-named label is never adopted — see
  # @label_lookup_query. A name nothing answers to is `:label_not_found`, which the
  # caller logs rather than raising on: an unmarked board is worse than a stopped run.
  defp resolve_label_id(issue_id, label_name) do
    case client_module().graphql(@label_lookup_query, %{issueId: issue_id, name: label_name}) do
      {:ok, response} ->
        team_id = get_in(response, ["data", "issue", "team", "id"])
        nodes = get_in(response, ["data", "issueLabels", "nodes"]) || []

        candidate =
          Enum.find(nodes, &(is_binary(team_id) and get_in(&1, ["team", "id"]) == team_id)) ||
            Enum.find(nodes, &is_nil(&1["team"]))

        case candidate do
          %{"id" => id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :label_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Who a claimed issue is assigned to. The orchestrator posts with the
  # automation key, so `viewer` is the bot — assigning to it hides the work from
  # the human running Symphony. Prefer the configured human assignee
  # (`tracker.assignee` / `LINEAR_ASSIGNEE`, a Linear user id or email); fall
  # back to the API actor only when none is configured.
  defp resolve_assignee_id do
    case Config.linear_claim_assignee() do
      value when is_binary(value) and value != "" -> resolve_configured_assignee(value)
      _ -> resolve_viewer_id()
    end
  end

  defp resolve_configured_assignee(value) do
    if uuid?(value), do: {:ok, value}, else: resolve_assignee_by_email(value)
  end

  defp uuid?(value) do
    Regex.match?(
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
      value
    )
  end

  defp resolve_assignee_by_email(email) do
    case client_module().graphql(@assignee_by_email_query, %{email: email}) do
      {:ok, %{"data" => %{"users" => %{"nodes" => [%{"id" => id} | _]}}}} when is_binary(id) ->
        {:ok, id}

      {:ok, _} ->
        {:error, :assignee_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_viewer_id do
    case client_module().graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"id" => id}}}} when is_binary(id) ->
        {:ok, id}

      {:ok, _} ->
        {:error, :viewer_id_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
