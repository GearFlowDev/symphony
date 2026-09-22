defmodule SymphonyElixir.Linear.FilterBuilder do
  @moduledoc """
  Compiles WORKFLOW.md filter config into a Linear GraphQL `IssueFilter` variable.

  Supports composable filters: project, labels (include/exclude), teams, priority,
  and state names. All fields are optional and AND'd together.
  """

  @doc """
  Build a Linear IssueFilter map from the tracker filter config.

  Accepts a map with any combination of:
    - `labels` — `%{include: [...], exclude: [...]}` or list of strings (treated as include)
    - `teams` — list of team key strings
    - `priority` — `%{max: N}` or `%{min: N}` (Linear: 1=urgent, 4=low)
    - `assignee` — not included in the GraphQL filter (handled by client-side routing)

  State filtering is handled separately by the caller (passed as a sibling filter).

  Returns a map suitable for use as the `$filter` GraphQL variable.
  """
  @spec build(map(), [String.t()]) :: map()
  def build(filter_config, state_names \\ []) when is_map(filter_config) do
    filters = []

    filters = maybe_add_labels_include(filters, filter_config)
    filters = maybe_add_teams(filters, filter_config)
    filters = maybe_add_priority(filters, filter_config)
    filters = maybe_add_states(filters, state_names)

    base =
      case filters do
        [] -> %{}
        [single] -> single
        multiple -> %{"and" => multiple}
      end

    # Label exclusion uses a separate top-level filter ANDed in
    base
    |> maybe_add_labels_exclude(filter_config)
  end

  @doc """
  Returns true if the filter config contains at least one targeting criterion.
  """
  @spec valid?(map()) :: boolean()
  def valid?(filter_config) when is_map(filter_config) do
    has_labels_include?(filter_config) or
      has_teams?(filter_config)
  end

  def valid?(_), do: false

  # ---------------------------------------------------------------------------
  # Label include filter
  # ---------------------------------------------------------------------------

  @doc """
  The labels `labels.include` targets, normalized.

  Public so the LIVE gate (is a running issue still routed here?) and the
  candidate QUERY read the same list through the same extraction — including
  the bare-list shorthand and atom keys. Two readers of this config disagreeing
  means dispatching an issue and stopping it again on the next poll.
  """
  @spec include_labels(map()) :: [String.t()]
  def include_labels(config) when is_map(config), do: extract_labels_include(config)

  def include_labels(_config), do: []

  defp maybe_add_labels_include(filters, config) do
    case extract_labels_include(config) do
      [] -> filters
      labels -> [%{"labels" => %{"name" => %{"in" => labels}}} | filters]
    end
  end

  defp extract_labels_include(%{labels: %{include: include}}) when is_list(include), do: normalize_strings(include)
  defp extract_labels_include(%{"labels" => %{"include" => include}}) when is_list(include), do: normalize_strings(include)
  # Bare list shorthand: `labels: ["symphony"]` treated as include
  defp extract_labels_include(%{labels: labels}) when is_list(labels), do: normalize_strings(labels)
  defp extract_labels_include(%{"labels" => labels}) when is_list(labels), do: normalize_strings(labels)
  defp extract_labels_include(_), do: []

  defp has_labels_include?(config), do: extract_labels_include(config) != []

  # ---------------------------------------------------------------------------
  # Label exclude filter — applied as additional AND conditions
  # ---------------------------------------------------------------------------

  defp maybe_add_labels_exclude(base_filter, config) do
    case extract_labels_exclude(config) do
      [] ->
        base_filter

      exclude_labels ->
        # Each excluded label becomes a separate NOT condition
        exclude_conditions =
          Enum.map(exclude_labels, fn label ->
            %{"labels" => %{"name" => %{"neq" => label}}}
          end)

        # Merge with existing filter via AND
        existing_and = Map.get(base_filter, "and", [])
        remaining = Map.delete(base_filter, "and")

        case {remaining, existing_and ++ exclude_conditions} do
          {r, conditions} when r == %{} -> %{"and" => conditions}
          {r, conditions} -> %{"and" => [r | conditions]}
        end
    end
  end

  defp extract_labels_exclude(%{labels: %{exclude: exclude}}) when is_list(exclude), do: normalize_strings(exclude)
  defp extract_labels_exclude(%{"labels" => %{"exclude" => exclude}}) when is_list(exclude), do: normalize_strings(exclude)
  defp extract_labels_exclude(_), do: []

  # ---------------------------------------------------------------------------
  # Team filter
  # ---------------------------------------------------------------------------

  defp maybe_add_teams(filters, config) do
    case extract_teams(config) do
      [] -> filters
      teams -> [%{"team" => %{"key" => %{"in" => teams}}} | filters]
    end
  end

  defp extract_teams(%{teams: teams}) when is_list(teams), do: normalize_strings(teams)
  defp extract_teams(%{"teams" => teams}) when is_list(teams), do: normalize_strings(teams)
  defp extract_teams(_), do: []

  defp has_teams?(config), do: extract_teams(config) != []

  # ---------------------------------------------------------------------------
  # Priority filter
  # ---------------------------------------------------------------------------

  defp maybe_add_priority(filters, config) do
    case extract_priority(config) do
      nil -> filters
      priority_filter -> [%{"priority" => priority_filter} | filters]
    end
  end

  defp extract_priority(%{priority: %{max: max}}) when is_integer(max), do: %{"lte" => max}
  defp extract_priority(%{"priority" => %{"max" => max}}) when is_integer(max), do: %{"lte" => max}
  defp extract_priority(%{priority: %{min: min}}) when is_integer(min), do: %{"gte" => min}
  defp extract_priority(%{"priority" => %{"min" => min}}) when is_integer(min), do: %{"gte" => min}
  defp extract_priority(_), do: nil

  # ---------------------------------------------------------------------------
  # State filter
  # ---------------------------------------------------------------------------

  defp maybe_add_states(filters, []), do: filters

  defp maybe_add_states(filters, state_names) when is_list(state_names) do
    [%{"state" => %{"name" => %{"in" => state_names}}} | filters]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_strings(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
