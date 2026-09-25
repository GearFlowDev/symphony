defmodule SymphonyElixir.NotifierCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notifier

  @moduletag :capture_log

  # A local webhook receiver: relays each POSTed JSON body to the test process
  # and answers with the status named in the request path.
  defmodule Receiver do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:webhook_body, conn.request_path, Jason.decode!(body)})
      status = conn.request_path |> String.trim_leading("/") |> String.to_integer()
      send_resp(conn, status, "")
    end
  end

  defp start_receiver! do
    pid = start_supervised!({Bandit, plug: {Receiver, self()}, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp use_webhook(url), do: write_workflow_file!(Workflow.workflow_file_path(), escalation_webhook_url: url)

  test "posts the webhook payload with sanitized details on success" do
    base = start_receiver!()
    use_webhook(base <> "/204")

    details = %{
      issue_id: "issue-1",
      identifier: "GEA-1",
      help_message: "stuck",
      issue: %{huge: "struct dropped"},
      phase: :implement,
      count: 3,
      flag: true,
      nothing: nil,
      list: [:a, "b", 1],
      pid: self()
    }

    log =
      capture_log(fn ->
        assert :ok = Notifier.notify_sync(:needs_human, details, comment_fn: fn _, _ -> :ok end)
      end)

    assert_received {:webhook_body, "/204", payload}
    assert payload["event"] == "needs_human"
    assert payload["issue_id"] == "issue-1"
    assert payload["issue_identifier"] == "GEA-1"
    assert {:ok, _, _} = DateTime.from_iso8601(payload["timestamp"])

    d = payload["details"]
    refute Map.has_key?(d, "issue")
    assert d["phase"] == "implement"
    assert d["count"] == 3
    assert d["flag"] == true
    assert d["nothing"] == nil
    assert d["list"] == ["a", "b", 1]
    assert d["pid"] =~ "#PID<"

    assert log =~ "sent needs_human webhook"
    assert log =~ "posted needs_human comment on GEA-1"
  end

  test "logs a non-2xx webhook response as a failure" do
    use_webhook(start_receiver!() <> "/500")

    log = capture_log(fn -> Notifier.notify_sync(:agent_stalled, %{identifier: "GEA-2", stall_reason: "x"}) end)

    assert_received {:webhook_body, "/500", %{"event" => "agent_stalled"}}
    assert log =~ "webhook failed for agent_stalled: {:http_status, 500}"
    assert log =~ "agent_stalled for GEA-2 (webhook only)"
  end

  test "logs a transport error from the webhook" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    use_webhook("http://127.0.0.1:#{port}/hook")

    log = capture_log(fn -> Notifier.notify_sync(:max_failure_retries_exhausted, %{issue_id: "i"}) end)
    assert log =~ "webhook failed for max_failure_retries_exhausted"
    assert log =~ "econnrefused"
  end

  test "an injected webhook_fn error is logged" do
    use_webhook("http://example.invalid/hook")
    webhook_fn = fn url, payload -> send(self(), {:hook, url, payload}) && {:error, :nope} end

    opts = [comment_fn: fn _, _ -> :ok end, webhook_fn: webhook_fn]
    log = capture_log(fn -> Notifier.notify_sync(:low_eval_score, %{issue_id: "i"}, opts) end)

    assert_received {:hook, "http://example.invalid/hook", %{event: "low_eval_score", issue_id: "i"}}
    assert log =~ "webhook failed for low_eval_score: :nope"
  end

  test "defaults comment posting to the configured tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Notifier.notify_sync(:needs_human, %{issue_id: "mem-1", help_message: "please look"})

    assert_received {:memory_tracker_comment, "mem-1", body}
    assert body =~ "> please look"
  end

  test "notify/2 posts through the configured tracker in the background" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok = Notifier.notify(:low_eval_score, %{issue_id: "bg-1", score: 12, threshold: 60, failing_checks: ["CI"]})

    assert_receive {:memory_tracker_comment, "bg-1", body}, 1_000
    assert body =~ "Evaluation score 12/100 (threshold: 60)"
    assert body =~ "- CI"
  end

  test "notify/3 runs the dispatch asynchronously" do
    test_pid = self()

    assert :ok =
             Notifier.notify(:needs_human, %{issue_id: "async-1"},
               comment_fn: fn id, body ->
                 send(test_pid, {:async_comment, id, body})
                 :ok
               end
             )

    assert_receive {:async_comment, "async-1", body}, 1_000
    assert body =~ "No details provided"
  end

  test "formats default and unexpected events" do
    assert Notifier.format_linear_comment(:max_continuations_exhausted, %{}) =~
             "Exhausted all 0 continuation attempts. Missing phases: ."

    assert Notifier.format_linear_comment(:max_failure_retries_exhausted, %{}) =~ "failed 0/0 times"
    assert Notifier.format_linear_comment(:low_eval_score, %{}) =~ "Evaluation score 0/100 (threshold: 0)"
    assert Notifier.format_linear_comment(:agent_stalled, %{}) =~ "restarted due to: unknown."
    assert Notifier.format_linear_comment(:mystery, %{}) == "## Symphony: mystery\n\nUnexpected event."
  end
end
