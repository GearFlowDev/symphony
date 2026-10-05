defmodule SymphonyElixir.Notifier do
  @moduledoc """
  Dispatches notifications when significant orchestration events occur.

  Posts a structured Linear comment (always) and optionally sends a webhook POST.
  All work runs asynchronously via Task.Supervisor — failures are logged, never raised.

  A PARK IS AN ASK, and an ask has one shape and one home (gf_engineering
  `CLAUDE.md` → Asking; GEA-10619). `:needs_human` posts a decision card — goal,
  status, problem, recommendation, then the ask with its default and its door — on
  the issue's PROJECT thread when the issue has a project, and on the issue when it
  has none. The issue then gets one line that links to the project and says how to
  resume, because the next run reads the issue's comments and not the project's.
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
    - `:project_fn` — override for `Tracker.fetch_issue_project/1`
    - `:project_comment_fn` — override for `Tracker.create_project_comment/2`
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
    cond do
      is_binary(issue_id) and event_type == :needs_human ->
        post_ask_card(details, issue_id, comment_fn, opts)

      is_binary(issue_id) and event_type not in @webhook_only_events ->
        post_linear_comment(event_type, details, issue_id, comment_fn)

      true ->
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

  # THE CARD GOES ON THE PROJECT THREAD, ONCE. A failed project read or a failed
  # project post falls back to the issue: an ask posted in the wrong place is a
  # smaller failure than an ask posted nowhere.
  defp post_ask_card(details, issue_id, comment_fn, opts) do
    project_fn = Keyword.get(opts, :project_fn, &Tracker.fetch_issue_project/1)
    project_comment_fn = Keyword.get(opts, :project_comment_fn, &Tracker.create_project_comment/2)
    body = format_linear_comment(:needs_human, details)
    who = details[:identifier] || issue_id

    with {:ok, %{id: project_id} = project} when is_binary(project_id) <- safely(fn -> project_fn.(issue_id) end),
         :ok <- safely(fn -> project_comment_fn.(project_id, body) end) do
      Logger.info("Notifier: posted the needs_human ask for #{who} on project #{project[:name] || project_id}")
      post_pointer(details, project, issue_id, comment_fn)
    else
      {:ok, nil} ->
        post_linear_comment(:needs_human, details, issue_id, comment_fn)

      other ->
        Logger.warning("Notifier: could not post the needs_human ask for #{who} on its project (#{inspect(other)}); posting it on the issue")
        post_linear_comment(:needs_human, details, issue_id, comment_fn)
    end
  end

  # A FAILED POINTER IS LOGGED, NOT RETRIED. The ask itself is posted, and posting the
  # card again on the issue would put one ask in two places — the thing the ask rule
  # forbids. The warning names where the ask is.
  defp post_pointer(details, project, issue_id, comment_fn) do
    who = details[:identifier] || issue_id
    pointer = format_linear_comment(:needs_human_pointer, Map.put(details, :project, project))

    case safely(fn -> comment_fn.(issue_id, pointer) end) do
      :ok ->
        Logger.info("Notifier: posted the needs_human pointer on #{who}")

      other ->
        Logger.warning("Notifier: the needs_human ask for #{who} is on project #{project[:name] || project[:id]}, but the pointer on the issue failed: #{inspect(other)}")
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
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

  # THE DECISION CARD (gf_engineering `.claude/skills/decision-brief/SKILL.md` § The
  # card): goal, status, problem, recommendation, then the ask with its default and its
  # door, in that order. Symphony cannot act on silence — a parked issue never dispatches
  # — so the default is "none" and the door is one-way: the issue waits for a person.
  def format_linear_comment(:needs_human, details) do
    card = ask_card(details)
    who = Map.get(details, :identifier) || "this issue"
    today = Date.to_iso8601(Date.utc_today())

    {status, default} =
      case Map.get(details, :parked_state) do
        state when is_binary(state) and state != "" ->
          {"Symphony stopped the run on #{today} and parked #{who} in #{state}. No run starts from #{state}.", "#{who} stays in #{state} until a person moves it."}

        _ ->
          {"Symphony stopped the run on #{today}.", "#{who} waits for a person."}
      end

    """
    ## Ask: #{card.question}

    **Goal.** Build #{issue_ref(details)} to a pull request under its grant.

    **Status.** #{status}

    **Problem.** #{card.problem}

    **Recommendation.** #{card.recommendation}

    **Ask.** #{card.question} Default: none. #{default} Door: one-way.

    To resume, write the answer or the fix on #{who} itself, then move #{who} to Todo. The next run reads #{who}'s comments, not a project thread, and it continues in the same slot.
    """
    |> String.trim()
  end

  def format_linear_comment(:needs_human_pointer, details) do
    project = Map.get(details, :project) || %{}
    name = project[:name] || "its project"
    where = if is_binary(project[:url]), do: "[#{name}](#{project[:url]})", else: name
    who = Map.get(details, :identifier) || "This issue"

    """
    **Symphony stopped #{who}. The ask is on the project thread of #{where}.**

    To resume, write the answer or the fix here, then move #{who} to Todo. The next run reads this issue's comments, not the project thread.
    """
    |> String.trim()
  end

  def format_linear_comment(event_type, _details) do
    "## Symphony: #{event_type}\n\nUnexpected event."
  end

  # The agent writes `SYMPHONY_NEEDS_HELP: <blocker> Ask: <question> Recommend: <what
  # and why>` (the preamble's shape). An orchestrator park carries only its reason, and
  # an agent may still write the bare form; both get a card, with the recommendation
  # marked as Symphony's own.
  defp ask_card(details) do
    message = details |> Map.get(:help_message, "") |> to_string() |> String.trim()
    {rest, recommend} = split_marker(message, "Recommend:")
    {blocker, ask} = split_marker(rest, "Ask:")
    who = issue_ref(details)

    case Map.get(details, :source, :orchestrator) do
      :agent ->
        %{
          question: ask || "Clear the blocker below and resume #{who}, or cancel it?",
          problem: "The agent stopped on a blocker it cannot clear under its grant: #{present(blocker)}",
          recommendation: recommend || "(Symphony's, the agent gave none.) Clear the blocker the agent names, then resume. Cancel the issue if the blocker means the work is no longer needed."
        }

      :planner ->
        %{
          question: ask || "Answer the plan's questions and resume #{who}?",
          problem: present(blocker),
          recommendation: recommend || "(Symphony's, the planner gave none.) Answer each question on #{who}, then resume."
        }

      _orchestrator ->
        %{
          question: "Fix the cause below and resume #{who}, or cancel it?",
          problem: "Symphony cannot advance the run: #{present(message)}",
          recommendation:
            "(Symphony's.) Read the plan rows and the latest grader and tester verdicts on the issue, and fix the cause or amend the issue body where they disagree, then resume. Cancel the issue if its scope no longer holds."
        }
    end
  end

  defp split_marker(text, marker) do
    case String.split(text, marker, parts: 2) do
      [before, after_marker] -> {String.trim(before), blank_to_nil(after_marker)}
      [whole] -> {whole, nil}
    end
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(""), do: "no details were given."
  defp present(text), do: text

  defp issue_ref(details) do
    identifier = Map.get(details, :identifier) || "this issue"

    case Map.get(details, :title) do
      title when is_binary(title) and title != "" -> ~s(#{identifier} "#{title}")
      _ -> identifier
    end
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
