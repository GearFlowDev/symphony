defmodule SymphonyElixir.Grant do
  @moduledoc """
  What Symphony is allowed to do with an issue, read from that issue's labels.

  WHY THIS EXISTS. Every run used to end the same way — a draft PR a person
  promoted — whatever the issue said. That is `Auto-Build` behaviour by accident,
  and it is wrong for the issues the machine owner marks for the harness to merge.
  The grant is the one thing that decides where a run stops, so it is read from
  Linear rather than assumed (GEA-9888).

  THE DEFAULT IS `Auto-Merge`, and that is not a guess. The runner label
  `auto-symphony` is both the route and the grant (GEA-9884, amended 2026-09-22):
  on its own it confers `Auto-Merge`. Symphony's tracker filter admits nothing
  without that label, so an issue reaching this module already carries it and an
  issue with no explicit Auto label beside it is an `Auto-Merge` issue.

  AN EXPLICIT AUTO LABEL NARROWS, it never widens: `Auto-Build` and `Auto-Design`
  stop the run at a ready PR with its proof posted, and a person merges.

  TO SYMPHONY, `Auto-Merge` DOES NOT MEAN MERGE. Symphony never merges its own
  work (GEA-9884, re-scoped 2026-09-21). It builds to mergeable, opens the PR and
  hands off; the harness judges the hand-off and merges. `Auto-User` is treated as
  `Auto-Merge` in this build — the assignee's wider authority is out of scope.
  """

  @type t :: :build | :design | :merge | :user

  # Lower-cased Linear label -> grant. Order does not matter: the narrowest
  # label on the issue wins, by @precedence below.
  @by_label %{
    "auto-build" => :build,
    "auto-design" => :design,
    "auto-merge" => :merge,
    "auto-user" => :user
  }

  # Narrowest first. An issue carrying two Auto labels is a mistake a person made,
  # and the safe reading of a mistake is the smaller grant.
  @precedence [:build, :design, :merge, :user]

  @default :merge

  @doc """
  The grant an issue's labels confer. `Auto-Merge` when no Auto label is present,
  because the runner label already conferred it.
  """
  @spec of([String.t()] | nil) :: t()
  def of(labels) when is_list(labels) do
    present =
      labels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.flat_map(fn label -> List.wrap(Map.get(@by_label, label)) end)

    Enum.find(@precedence, @default, &(&1 in present))
  end

  def of(_labels), do: @default

  @doc "The Linear label this grant is spelled with, for a prompt or a log line."
  @spec label(t()) :: String.t()
  def label(:build), do: "Auto-Build"
  def label(:design), do: "Auto-Design"
  def label(:merge), do: "Auto-Merge"
  def label(:user), do: "Auto-User"

  @doc """
  Does this grant end in a hand-off to the harness?

  `Auto-Build` and `Auto-Design` end at the PR and a person takes it from there,
  so there is nothing to hand off to a machine.
  """
  @spec hands_off?(t()) :: boolean()
  def hands_off?(grant), do: grant in [:merge, :user]

  @doc """
  Where the run stops, in the words the stage prompts show the agent.

  Every grant ends at a PR: a run that ends without one is broken, not handed off
  (GEA-9888, the machine owner's rule of 2026-09-22).
  """
  @spec finish_line(t()) :: String.t()
  def finish_line(:build) do
    "a ready pull request with its proof posted on the issue. A person reviews and merges it. " <>
      "You do not merge, and you do not answer product questions — ask them on the issue instead."
  end

  def finish_line(:design) do
    "a ready pull request with its proof posted on the issue. A person reviews and merges it. " <>
      "Product questions on the way are yours to settle: decide, build it that way, and say why on the issue."
  end

  def finish_line(:merge) do
    "a ready pull request that is mergeable, handed off to the harness. " <>
      "You never merge it yourself: the harness judges the hand-off and merges."
  end

  def finish_line(:user), do: finish_line(:merge)

  @doc "The grant as the stage templates see it."
  @spec to_template_map(t()) :: map()
  def to_template_map(grant) do
    %{
      "label" => label(grant),
      "finish_line" => finish_line(grant),
      "hands_off" => hands_off?(grant)
    }
  end
end
