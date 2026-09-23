defmodule SymphonyElixir.Notifier do
  @moduledoc """
  Dispatches notifications when significant orchestration events occur.

  Posts a structured Linear comment (always) and optionally sends a webhook POST.
  All work runs asynchronously via Task.Supervisor — failures are logged, never raised.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}

  @type event_type ::
          :max_continuations_exhausted
          | :max_failure_retries_exhausted
          | :low_eval_score
          | :agent_stalled
          | :needs_human

  @doc """
  Send a notification for the given event. Non-blocking.

  Options (for testing):
    - `:comment_fn` — override for `Tracker.create_comment/2`
    - `:webhook_fn` — override for `&send_webhook/2`
  """
  @spec notify(event_type(), map(), keyword()) :: :ok
  def notify(event_type, details, opts \\ []) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      do_notify(event_type, details, opts)
    end)

    :ok
  end

  @doc """
  Synchronous notification dispatch. Useful for testing.
  """
  @spec notify_sync(event_type(), map(), keyword()) :: :ok
  def notify_sync(event_type, details, opts \\ []) do
    do_notify(event_type, details, opts)
    :ok
  end

  # These events are operational noise — log and webhook only, no Linear comment.
  @webhook_only_events [:agent_stalled, :max_failure_retries_exhausted, :max_continuations_exhausted]

  defp do_notify(event_type, details, opts) do
    issue_id = Map.get(details, :issue_id)
    comment_fn = Keyword.get(opts, :comment_fn, &Tracker.create_comment/2)
    webhook_fn = Keyword.get(opts, :webhook_fn, &send_webhook/2)

    # Post Linear comment (skip for operational events)
    if is_binary(issue_id) and event_type not in @webhook_only_events do
      post_linear_comment(event_type, details, issue_id, comment_fn)
    else
      Logger.info("Notifier: #{event_type} for #{details[:identifier] || issue_id} (webhook only)")
    end

    # Send webhook
    webhook_url = Config.escalation_webhook_url()

    if is_binary(webhook_url) do
      send_webhook_notification(event_type, details, webhook_url, webhook_fn)
    end
  rescue
    error ->
      Logger.warning("Notifier: unexpected error in #{event_type}: #{Exception.message(error)}")
  end

  defp post_linear_comment(event_type, details, issue_id, comment_fn) do
    body = format_linear_comment(event_type, details)

    case comment_fn.(issue_id, body) do
      :ok ->
        Logger.info("Notifier: posted #{event_type} comment on #{details[:identifier] || issue_id}")

      {:error, reason} ->
        Logger.warning("Notifier: failed to post comment for #{event_type}: #{inspect(reason)}")
    end
  end

  defp send_webhook_notification(event_type, details, webhook_url, webhook_fn) do
    payload = build_webhook_payload(event_type, details)

    case webhook_fn.(webhook_url, payload) do
      :ok ->
        Logger.info("Notifier: sent #{event_type} webhook")

      {:error, reason} ->
        Logger.warning("Notifier: webhook failed for #{event_type}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Linear comment formatting
  # ---------------------------------------------------------------------------

  @doc false
  @spec format_linear_comment(event_type() | atom(), map()) :: String.t()
  def format_linear_comment(:max_continuations_exhausted, details) do
    missing = Map.get(details, :missing_phases, [])
    count = Map.get(details, :continuation_count, 0)

    """
    ## Symphony: Agent Gave Up

    Exhausted all #{count} continuation attempts. Missing phases: #{Enum.join(missing, ", ")}.

    This issue needs human attention.
    """
    |> String.trim()
  end

  def format_linear_comment(:max_failure_retries_exhausted, details) do
    attempt = Map.get(details, :attempt, 0)
    max = Map.get(details, :max_retries, 0)

    """
    ## Symphony: Max Retries Exhausted

    Agent failed #{attempt}/#{max} times and will not retry.

    This issue needs human attention.
    """
    |> String.trim()
  end

  def format_linear_comment(:low_eval_score, details) do
    score = Map.get(details, :score, 0)
    threshold = Map.get(details, :threshold, 0)
    failing = Map.get(details, :failing_checks, [])

    checks_list = Enum.map_join(failing, "\n", &"- #{&1}")

    """
    ## Symphony: Low Quality Score

    Evaluation score #{score}/100 (threshold: #{threshold}).

    Failing checks:
    #{checks_list}

    This issue needs human attention.
    """
    |> String.trim()
  end

  def format_linear_comment(:agent_stalled, details) do
    reason = Map.get(details, :stall_reason, "unknown")

    """
    ## Symphony: Agent Stalled

    Agent was restarted due to: #{reason}.
    """
    |> String.trim()
  end

  def format_linear_comment(:needs_human, details) do
    message = Map.get(details, :help_message, "No details provided")

    """
    ## Symphony: Agent Needs Help

    The agent has requested human assistance:

    > #{message}

    Please review and provide guidance.
    """
    |> String.trim()
  end

  def format_linear_comment(event_type, _details) do
    "## Symphony: #{event_type}\n\nUnexpected event."
  end

  # ---------------------------------------------------------------------------
  # Webhook
  # ---------------------------------------------------------------------------

  defp build_webhook_payload(event_type, details) do
    %{
      event: to_string(event_type),
      issue_id: Map.get(details, :issue_id),
      issue_identifier: Map.get(details, :identifier),
      details: sanitize_for_json(details),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp send_webhook(url, payload) do
    case Req.post(url, json: payload, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sanitize_for_json(map) when is_map(map) do
    map
    |> Map.drop([:issue])
    |> Map.new(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_binary(v), do: v
  defp sanitize_value(v) when is_number(v), do: v
  defp sanitize_value(v) when is_boolean(v), do: v
  defp sanitize_value(v) when is_nil(v), do: nil
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)
  defp sanitize_value(v) when is_atom(v), do: to_string(v)
  defp sanitize_value(v), do: inspect(v)
end
