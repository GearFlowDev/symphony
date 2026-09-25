defmodule SymphonyElixir.SuitabilityCoverageTest do
  @moduledoc """
  Screens issues against suitability rules read from a real WORKFLOW.md, so the
  config wiring and the screening logic are exercised together.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Suitability

  defp with_suitability!(yaml_lines) do
    path = Workflow.workflow_file_path()
    ["", front, prompt] = path |> File.read!() |> String.split("---\n", parts: 3)
    File.write!(path, "---\n" <> front <> "suitability:\n" <> Enum.join(yaml_lines, "\n") <> "\n---\n" <> prompt)
    WorkflowStore.force_reload()
  end

  defp issue(attrs) do
    struct(%Issue{id: "i", identifier: "S-1", description: "has body", priority: 2, labels: ["bug"]}, attrs)
  end

  test "skips an issue carrying an excluded label, case-insensitively" do
    with_suitability!(["  skip_labels: [\"Epic\", \"needs-design\"]"])

    assert Suitability.screen(issue(labels: ["bug", "EPIC"])) == {:skip, :excluded_label}
    assert Suitability.screen(issue(labels: ["bug"])) == :ok
  end

  test "skips a blank description when one is required" do
    with_suitability!(["  require_description: true"])

    assert Suitability.screen(issue(description: nil)) == {:skip, :no_description}
    assert Suitability.screen(issue(description: "  \n ")) == {:skip, :no_description}
    assert Suitability.screen(issue(description: "real")) == :ok
  end

  test "skips issues at or below the minimum priority" do
    with_suitability!(["  min_priority: 3"])

    assert Suitability.screen(issue(priority: 3)) == {:skip, :low_priority}
    assert Suitability.screen(issue(priority: 4)) == {:skip, :low_priority}
    assert Suitability.screen(issue(priority: 2)) == :ok
    assert Suitability.screen(issue(priority: nil)) == :ok
  end
end
