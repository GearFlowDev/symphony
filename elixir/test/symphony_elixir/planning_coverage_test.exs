defmodule SymphonyElixir.PlanningCoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Planning
  alias SymphonyElixir.Planning.{Dispatch, Plan}
  alias SymphonyElixir.Repo

  # Stands in for the Linear GraphQL client so the Tracker's Linear adapter can
  # succeed, fail or crash on demand. It runs in the test process.
  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(self(), {:graphql, query, variables})

      case Process.get(:linear_mode, :ok) do
        :ok ->
          if query =~ "commentUpdate" do
            {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
          else
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-new"}}}}}
          end

        :fail ->
          {:error, :linear_down}

        :raise ->
          raise "linear exploded"
      end
    end
  end

  setup_all do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-planning-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow_file = Path.join(root, "WORKFLOW.md")

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
    claude:
      model: opus
    ---
    prompt
    """)

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        module -> Application.put_env(:symphony_elixir, :linear_client_module, module)
      end

      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(root)
    end)

    :ok
  end

  defp migrations_path do
    Path.join([Application.app_dir(:symphony_elixir), "..", "..", "..", "..", "priv", "repo", "migrations"])
    |> Path.expand()
  end

  defp unique_identifier, do: "COV-#{System.unique_integer([:positive])}"

  defp insert_plan(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          issue_id: "linear-uuid-cov",
          issue_identifier: unique_identifier(),
          plan_json: %{"rows" => [%{"id" => "R1", "description" => "First row", "state" => "missing"}]}
        },
        overrides
      )

    {:ok, plan} = Planning.upsert_plan(attrs)
    plan
  end

  describe "get_plan_by_issue/1" do
    test "returns the stored plan for the identifier and nil for an unknown one" do
      plan = insert_plan()

      assert %Plan{id: id} = Planning.get_plan_by_issue(plan.issue_identifier)
      assert id == plan.id
      assert Planning.get_plan_by_issue(unique_identifier()) == nil
    end
  end

  describe "upsert_plan/1 and update_plan/2" do
    test "rejects a plan without an issue id" do
      assert {:error, changeset} = Planning.upsert_plan(%{issue_identifier: unique_identifier()})
      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "a re-plan keeps the Linear mirror comment id" do
      plan = insert_plan()
      {:ok, _} = Planning.update_plan(plan, %{linear_comment_id: "keep-me"})

      {:ok, replanned} =
        Planning.upsert_plan(%{issue_id: plan.issue_id, issue_identifier: plan.issue_identifier, status: "grading"})

      assert replanned.id == plan.id
      assert replanned.status == "grading"
      assert Planning.get_plan_by_issue(plan.issue_identifier).linear_comment_id == "keep-me"
    end

    test "set_plan_status/2 accepts a known status and rejects an unknown one" do
      plan = insert_plan()

      assert {:ok, %Plan{status: "done"}} = Planning.set_plan_status(plan, "done")
      assert {:error, changeset} = Planning.set_plan_status(plan, "exploded")
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "replace_rows/2" do
    test "creates the rows key when plan_json is nil" do
      plan = %{insert_plan() | plan_json: nil}

      assert {:ok, updated} = Planning.replace_rows(plan, [%{"id" => "R9", "description" => "d", "state" => "done"}])
      assert updated.plan_json == %{"rows" => [%{"id" => "R9", "description" => "d", "state" => "done"}]}
    end
  end

  describe "render_plan_comment/1" do
    test "renders a placeholder when the plan has no rows" do
      plan = insert_plan(%{plan_json: %{}})
      assert Planning.render_plan_comment(plan) =~ "_(no rows)_"
    end

    test "fills defaults for a row without id or state and marks deferred rows" do
      plan =
        insert_plan(%{
          plan_json: %{
            "rows" => [
              %{"description" => "anonymous", "rationale" => ""},
              %{"id" => "R2", "state" => "deferred"}
            ]
          }
        })

      md = Planning.render_plan_comment(plan)
      assert md =~ "- ⬜ **?** (missing) — anonymous"
      assert md =~ "- ⏭️ **R2** (deferred) — "
      # An empty rationale adds no sub-bullet.
      refute md =~ "\n    - "
    end
  end

  describe "mirror_plan_to_linear/1" do
    test "posts a new comment the first time and stores its id" do
      plan = insert_plan()

      mirrored = Planning.mirror_plan_to_linear(plan)

      assert mirrored.linear_comment_id == "comment-new"
      assert Planning.get_plan_by_issue(plan.issue_identifier).linear_comment_id == "comment-new"
      assert_received {:graphql, query, %{issueId: "linear-uuid-cov", body: body}}
      assert query =~ "commentCreate"
      assert body == Planning.render_plan_comment(plan)
    end

    test "edits the existing comment in place once one is stored" do
      {:ok, plan} = Planning.update_plan(insert_plan(), %{linear_comment_id: "comment-old"})

      assert Planning.mirror_plan_to_linear(plan) == plan
      assert_received {:graphql, query, %{id: "comment-old", body: _}}
      assert query =~ "commentUpdate"
    end

    test "returns the plan unchanged when posting the comment fails" do
      plan = insert_plan()
      Process.put(:linear_mode, :fail)

      log =
        capture_log(fn ->
          assert Planning.mirror_plan_to_linear(plan) == plan
        end)

      assert log =~ "failed to post comment for #{plan.issue_identifier}"
      assert Planning.get_plan_by_issue(plan.issue_identifier).linear_comment_id == nil
    end

    test "returns the plan unchanged when editing the comment fails" do
      {:ok, plan} = Planning.update_plan(insert_plan(), %{linear_comment_id: "comment-old"})
      Process.put(:linear_mode, :fail)

      log =
        capture_log(fn ->
          assert Planning.mirror_plan_to_linear(plan) == plan
        end)

      assert log =~ "failed to update comment for #{plan.issue_identifier}"
    end

    test "a crashing tracker never escapes the mirror" do
      plan = insert_plan()
      Process.put(:linear_mode, :raise)

      log =
        capture_log(fn ->
          assert Planning.mirror_plan_to_linear(plan) == plan
        end)

      assert log =~ "Plan mirror crashed for #{plan.issue_identifier}: linear exploded"
    end
  end

  describe "dispatches" do
    test "record_dispatch/1 rejects an unknown role" do
      plan = insert_plan()

      assert {:error, changeset} = Planning.record_dispatch(%{plan_id: plan.id, role: "deploy"})
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "dispatches_for_plan/1 accepts a bare plan id" do
      plan = insert_plan()
      {:ok, dispatch} = Planning.record_dispatch(%{plan_id: plan.id, role: "test"})

      assert [%Dispatch{id: id}] = Planning.dispatches_for_plan(plan.id)
      assert id == dispatch.id
    end
  end

  describe "schema helpers" do
    test "Plan.rows/1 is empty for a plan_json without a rows list" do
      assert Plan.rows(%Plan{plan_json: %{"rows" => "not a list"}}) == []
      assert Plan.open_rows(%Plan{plan_json: nil}) == []
    end

    test "status and role vocabularies" do
      assert Plan.statuses() == ~w(planning dispatching grading done failed)
      assert Dispatch.roles() == ~w(implement test regrade)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
