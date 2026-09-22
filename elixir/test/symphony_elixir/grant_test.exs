defmodule SymphonyElixir.GrantTest do
  @moduledoc """
  The grant is read from the issue's labels, and it is what decides where a run
  stops (GEA-9888).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Grant

  test "the runner label alone confers Auto-Merge" do
    # `auto-symphony` routes AND grants (GEA-9884, amended 2026-09-22). Symphony's
    # tracker filter admits nothing without it, so an issue with no Auto label
    # beside it is an Auto-Merge issue and not an ungranted one.
    assert Grant.of(["auto-symphony"]) == :merge
    assert Grant.of([]) == :merge
    assert Grant.of(nil) == :merge
  end

  test "an explicit Auto label narrows the run" do
    assert Grant.of(["auto-symphony", "Auto-Build"]) == :build
    assert Grant.of(["auto-symphony", "Auto-Design"]) == :design
    assert Grant.of(["auto-symphony", "Auto-Merge"]) == :merge
    assert Grant.of(["auto-symphony", "Auto-User"]) == :user
  end

  test "two Auto labels read as the narrower one" do
    # An issue wearing two grants is a mistake a person made; the safe reading of
    # a mistake is the smaller grant, whatever order Linear returns them in.
    assert Grant.of(["Auto-Merge", "Auto-Build"]) == :build
    assert Grant.of(["Auto-Build", "Auto-Merge"]) == :build
    assert Grant.of(["Auto-User", "Auto-Design"]) == :design
  end

  test "label spelling and stray whitespace do not change the grant" do
    assert Grant.of([" auto-build "]) == :build
    assert Grant.of(["AUTO-MERGE"]) == :merge
    assert Grant.of(["Bugfix", nil, 3, "auto-design"]) == :design
  end

  test "only Auto-Merge and Auto-User hand off; Symphony never merges under any of them" do
    assert Grant.hands_off?(:merge)
    assert Grant.hands_off?(:user)
    refute Grant.hands_off?(:build)
    refute Grant.hands_off?(:design)

    for grant <- [:build, :design, :merge, :user] do
      refute Grant.finish_line(grant) =~ ~r/\byou merge\b/i
      assert Grant.finish_line(grant) =~ "pull request"
    end
  end

  test "Auto-User is Auto-Merge in this build" do
    assert Grant.finish_line(:user) == Grant.finish_line(:merge)
  end

  test "each grant names who merges, and only Design invites product decisions" do
    assert Grant.finish_line(:build) =~ "A person reviews and merges it"
    assert Grant.finish_line(:design) =~ "A person reviews and merges it"
    assert Grant.finish_line(:design) =~ "Product questions"
    refute Grant.finish_line(:build) =~ "Product questions on the way are yours"
    assert Grant.finish_line(:merge) =~ "the harness judges the hand-off and merges"
  end

  test "the template map carries the label, the finish line and whether it hands off" do
    assert %{"label" => "Auto-Build", "finish_line" => line, "hands_off" => false} =
             Grant.to_template_map(:build)

    assert line == Grant.finish_line(:build)
  end
end
