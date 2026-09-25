defmodule SymphonyElixir.History.TesterVerdictCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.History.TesterVerdict

  test "accepts a known verdict with its issue" do
    changeset =
      TesterVerdict.create_changeset(%{issue_identifier: "GEA-1", verdict: "APPROVE", commit_sha: "abc123", reason: "ok"})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :commit_sha) == "abc123"
  end

  test "requires an issue and a verdict" do
    changeset = TesterVerdict.create_changeset(%{})

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:issue_identifier]
    assert {"can't be blank", _} = changeset.errors[:verdict]
  end

  test "rejects a verdict outside the vocabulary" do
    changeset = TesterVerdict.create_changeset(%{issue_identifier: "GEA-1", verdict: "approve"})

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:verdict]
  end
end
