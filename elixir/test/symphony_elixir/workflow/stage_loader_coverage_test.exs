defmodule SymphonyElixir.Workflow.StageLoaderCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow.StageLoader

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-stages-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write(dir, name, content), do: File.write!(Path.join(dir, name), content)

  describe "load_stages/1" do
    test "reads only readable .md files", %{dir: dir} do
      write(dir, "01-plan.md", "plan")
      write(dir, "_preamble.md", "pre")
      write(dir, "notes.txt", "ignored")
      # A dangling symlink is listed but cannot be read.
      File.ln_s!(Path.join(dir, "missing-target"), Path.join(dir, "02-broken.md"))

      assert StageLoader.load_stages(dir) == %{"01-plan.md" => "plan", "_preamble.md" => "pre"}
    end

    test "returns an empty map for a missing directory", %{dir: dir} do
      assert StageLoader.load_stages(Path.join(dir, "nope")) == %{}
    end
  end

  describe "assemble_prompt/1" do
    test "returns an empty string for no stages" do
      assert StageLoader.assemble_prompt(%{}) == ""
    end

    test "joins preamble, numbered stages in order, then partials, skipping templates" do
      stages = %{
        "_preamble.md" => "PREAMBLE",
        "02-test.md" => "TEST",
        "00-intro.md" => "INTRO",
        "_zeta.md" => "ZETA",
        "_alpha.md" => "ALPHA",
        "_continuation.md" => "CONT",
        "_retask.md" => "RETASK",
        "_empty.md" => "",
        "readme.md" => "OTHER"
      }

      assert StageLoader.assemble_prompt(stages) ==
               Enum.join(["PREAMBLE", "INTRO", "TEST", "ALPHA", "ZETA"], "\n\n---\n\n")
    end

    test "works without a preamble" do
      assert StageLoader.assemble_prompt(%{"01-a.md" => "  A  "}) == "A"
    end
  end

  describe "assemble_continuation/4" do
    test "returns nil without a continuation template" do
      assert StageLoader.assemble_continuation(%{}, 1, 5, []) == nil
    end

    test "fills turn numbers and leaves the comment slot empty without comments" do
      stages = %{"_continuation.md" => "Turn {{turn_number}}/{{max_turns}}.{{comments_section}}"}
      assert StageLoader.assemble_continuation(stages, 2, 9, []) == "Turn 2/9."
    end

    test "formats comments with their time, or ? when the time is unknown" do
      stages = %{"_continuation.md" => "{{comments_section}}"}

      comments = [
        %{author: "ana", body: "please add a test", created_at: ~U[2026-09-25 14:05:00Z]},
        %{author: "bo", body: "and docs"}
      ]

      text = StageLoader.assemble_continuation(stages, 1, 1, comments)

      assert text =~ "## New comments on the Linear issue"
      assert text =~ "  [14:05 UTC] ana: please add a test"
      assert text =~ "  [?] bo: and docs"
    end
  end

  describe "phase_content/2" do
    @stage """
    # Stage

    ## Step 1: Implementation notes
    not this one

    ## Step 2: Implement
    Do the work.

    ```
    ## Tester Report
    inside a fence
    ```

    After fence.

    ## Step 3: Share Evidence on Linear
    Post screenshots.
    """

    test "extracts a phase section by whole word, keeping fenced headings" do
      stages = %{"01-work.md" => @stage, "_partial.md" => "## Step 9: Implement\nignored partial"}

      content = StageLoader.phase_content(stages, "Implement")

      assert content =~ "## Step 2: Implement"
      assert content =~ "## Tester Report\ninside a fence"
      assert content =~ "After fence."
      refute content =~ "not this one"
      refute content =~ "Post screenshots."
      refute content =~ "ignored partial"
    end

    test "matches case-insensitively and reads the last section to the end" do
      assert StageLoader.phase_content(%{"01-work.md" => @stage}, "share evidence") ==
               "## Step 3: Share Evidence on Linear\nPost screenshots."
    end

    test "uses the first numbered stage that has the phase" do
      stages = %{"02-b.md" => "## Deploy\nsecond", "01-a.md" => "## Deploy\nfirst"}
      assert StageLoader.phase_content(stages, "Deploy") == "## Deploy\nfirst"
    end

    test "returns nil when no stage has the phase" do
      assert StageLoader.phase_content(%{"01-work.md" => @stage}, "Deploy") == nil
      assert StageLoader.phase_content(%{}, "Deploy") == nil
    end
  end

  describe "load_retask_template/1" do
    test "returns the template or nil", %{dir: dir} do
      assert StageLoader.load_retask_template(dir) == nil
      write(dir, "_retask.md", "retask {{x}}")
      assert StageLoader.load_retask_template(dir) == "retask {{x}}"
    end
  end

  describe "directory_stamp/1" do
    test "changes when a stage file changes and ignores other files", %{dir: dir} do
      write(dir, "01-a.md", "one")
      {:ok, stamp1} = StageLoader.directory_stamp(dir)

      write(dir, "notes.txt", "ignored")
      assert {:ok, ^stamp1} = StageLoader.directory_stamp(dir)

      write(dir, "01-a.md", "one plus more")
      assert {:ok, stamp2} = StageLoader.directory_stamp(dir)
      assert stamp2 != stamp1
    end

    test "stamps an unreadable stage file instead of failing", %{dir: dir} do
      File.ln_s!(Path.join(dir, "missing-target"), Path.join(dir, "01-broken.md"))
      assert {:ok, stamp} = StageLoader.directory_stamp(dir)
      assert stamp == :erlang.phash2([{"01-broken.md", 0, 0}])
    end

    test "returns the error for a missing directory", %{dir: dir} do
      assert {:error, :enoent} = StageLoader.directory_stamp(Path.join(dir, "nope"))
    end
  end
end
