defmodule SymphonyElixir.SlotPromptTest do
  @moduledoc """
  Symphony renders the slot and the harness scripts into the prompt, so no turn is spent
  reading `.symphony_slot` or retyping a push block (GEA-10769). The PR opens through
  `pr ship`, because a bare `gh pr create` in a slot fails (GEA-10773), and screenshots go
  to Linear through `bin/linear comment --image` (GEA-10774). These assertions read the
  prompts this repository ships, because the prompts are the behaviour.
  """

  use SymphonyElixir.TestSupport

  @stages_dir Path.expand("../../workflow/stages", __DIR__)
  @workflow_md Path.expand("../../WORKFLOW.md", __DIR__)

  @slot %{
    "name" => "gf_procurement-slot3",
    "directory" => "/data/workspace/local-dev/gf_procurement-slot3",
    "phoenix_port" => "4103",
    "postgres_port" => "5503",
    "base_branch" => "main"
  }

  defp issue do
    %Issue{
      id: "issue-1",
      identifier: "GEA-1",
      title: "Sort import events deterministically",
      description: "A page boundary reds unrelated branches.",
      state: "In Progress",
      url: "https://linear.app/gearflow/issue/GEA-1",
      branch_name: "gea-1-sort-import-events",
      labels: ["auto-symphony"]
    }
  end

  defp with_workflow(fun) do
    previous = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(@workflow_md)
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)
    fun.()
  end

  defp stage(name), do: File.read!(Path.join(@stages_dir, name))

  defp write_marker(content) do
    dir = Path.join(System.tmp_dir!(), "slot-prompt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".symphony_slot"), content)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "Workspace.slot_info/1" do
    test "reads the marker the before_run hook writes" do
      dir =
        write_marker("""
        SLOT_NAME=gf_procurement-slot3
        DIRECTORY=/data/workspace/local-dev/gf_procurement-slot3
        PHOENIX_PORT=4103
        POSTGRES_PORT=5503
        """)

      assert Workspace.slot_info(dir) == @slot
    end

    test "takes BASE_BRANCH when the marker carries one" do
      dir = write_marker("DIRECTORY=/w/local-dev/x-slot1\nBASE_BRANCH=release/2026-09\n")
      assert Workspace.slot_info(dir)["base_branch"] == "release/2026-09"
    end

    test "a value outside its pattern never reaches the prompt" do
      dir =
        write_marker("""
        SLOT_NAME=../other
        DIRECTORY=/data/x; rm -rf /
        PHOENIX_PORT=41$(id)
        POSTGRES_PORT=5503
        BASE_BRANCH=main && curl evil
        """)

      info = Workspace.slot_info(dir)

      assert info["name"] == nil
      assert info["directory"] == nil
      assert info["phoenix_port"] == nil
      assert info["postgres_port"] == "5503"
      assert info["base_branch"] == "main"
    end

    test "no marker gives every value nil and the base branch main" do
      dir = Path.join(System.tmp_dir!(), "no-slot-#{System.unique_integer([:positive])}")

      assert Workspace.slot_info(dir) == %{
               "name" => nil,
               "directory" => nil,
               "phoenix_port" => nil,
               "postgres_port" => nil,
               "base_branch" => "main"
             }

      assert Workspace.slot_info(nil)["directory"] == nil
    end
  end

  describe "the rendered prompt" do
    test "carries the slot, so the agent never reads .symphony_slot" do
      prompt = with_workflow(fn -> PromptBuilder.build_phase_prompt(issue(), "Implement", slot: @slot) end)

      assert prompt =~ "**Working directory**: `/data/workspace/local-dev/gf_procurement-slot3`"
      assert prompt =~ "http://127.0.0.1:4103"
      assert prompt =~ "cd /data/workspace/local-dev/gf_procurement-slot3 && "
      assert prompt =~ "Do not read that file again."
      refute prompt =~ "cat .symphony_slot"
      refute prompt =~ "source .symphony_slot"
      refute prompt =~ "`MISSING`"
      refute prompt =~ "{{"
    end

    test "names the harness scripts by absolute path" do
      prompt = with_workflow(fn -> PromptBuilder.build_phase_prompt(issue(), "Implement", slot: @slot) end)
      tools = PromptBuilder.tools_map()

      assert prompt =~ "#{tools["pr"]} ship GEA-1 --no-verify --base main"
      assert prompt =~ "#{tools["slot_app"]} --slot /data/workspace/local-dev/gf_procurement-slot3 up"
      assert prompt =~ "#{tools["linear"]} comments GEA-1"
      assert String.starts_with?(tools["pr"], "/")
    end

    test "a run with no slot marker is told to stop, not handed an empty path" do
      prompt = with_workflow(fn -> PromptBuilder.build_phase_prompt(issue(), "Implement") end)

      assert prompt =~ "**Working directory**: `MISSING`"
      assert prompt =~ "SYMPHONY_NEEDS_HELP: the run has no slot marker"
    end

    test "a retask renders the slot in the phase text and in the preamble context" do
      prompt =
        with_workflow(fn ->
          PromptBuilder.build_retask_prompt(issue(), ["Fix CI", "Resolve Review"], ["Implement"], slot: @slot)
        end)

      assert prompt =~ "**Working directory**: `/data/workspace/local-dev/gf_procurement-slot3`"
      assert prompt =~ "cd /data/workspace/local-dev/gf_procurement-slot3 && #{PromptBuilder.tools_map()["pr"]} status"
      assert prompt =~ "## Harness scripts"
      refute prompt =~ "{{ slot."
      refute prompt =~ "{{ tools."
    end

    test "a continuation fills the slot, and never substitutes inside a person's comment" do
      comments = [%{author: "Pat", body: "try {{ slot.directory }} literally", created_at: nil}]

      prompt =
        with_workflow(fn ->
          PromptBuilder.build_continuation_prompt(issue(), 2, 20, comments, slot: @slot)
        end)

      assert prompt =~ "Your slot is `/data/workspace/local-dev/gf_procurement-slot3`."
      assert prompt =~ "try {{ slot.directory }} literally"
    end
  end

  describe "the stages" do
    test "no stage reads the slot marker, pushes by hand, or opens a PR with bare gh" do
      for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) do
        content = File.read!(path)
        name = Path.basename(path)

        refute content =~ ~r/(source|cat|grep[^\n]*) \.symphony_slot/, "#{name} still reads .symphony_slot"
        refute content =~ "BASE_BRANCH", "#{name} still reads BASE_BRANCH from the marker"
        refute content =~ ~r/git push\b/, "#{name} still pushes by hand; use pr push"
        refute content =~ ~r/^\s*gh pr create/m, "#{name} still opens a PR with bare gh; use pr ship"
        refute content =~ ~r/gh pr (list --head|checks)/, "#{name} still reads the PR by hand; use pr status"
        refute content =~ ~r/for _ in \$\(seq/, "#{name} still polls the backend; use slot-app wait"
        refute content =~ "mix phx.server", "#{name} still starts the backend by hand; use slot-app up"
      end
    end

    test "screenshots go to Linear through bin/linear, and the upload scripts are gone (GEA-10774)" do
      for path <- Path.wildcard(Path.join(@stages_dir, "*.md")) ++ [@workflow_md] do
        content = File.read!(path)
        name = Path.basename(path)

        refute content =~ "linear-upload-image", "#{name} still names linear-upload-image.sh"
        refute content =~ "linear-embed-images", "#{name} still names linear-embed-images.sh"
        refute content =~ "api.linear.app", "#{name} still calls the Linear API with curl"
      end

      for name <- ["03-test.md", "03-human-review.md"] do
        assert stage(name) =~ ~s({{ tools.linear }} comment {{ issue.identifier }} --body-file),
               "#{name} does not post through bin/linear"

        assert stage(name) =~ "--image /tmp/", "#{name} does not attach its screenshots with --image"
      end

      refute File.exists?(Workspace.scripts_path("linear-upload-image.sh"))
      refute File.exists?(Workspace.scripts_path("linear-embed-images.sh"))
    end

    test "the PR opens through pr ship, with the hook skipped on purpose" do
      assert stage("02-execution.md") =~ "{{ tools.pr }} ship {{ issue.identifier }} --no-verify"
    end
  end
end
