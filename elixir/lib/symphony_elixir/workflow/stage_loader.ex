defmodule SymphonyElixir.Workflow.StageLoader do
  @moduledoc """
  Loads and assembles staged workflow prompts from `workflow/stages/` directory.

  Files with `_` prefix are partials (included by others, not standalone stages).
  Files with numeric prefix are ordered stages.
  """

  require Logger

  @doc """
  Reads all `.md` files from the stages directory.
  Returns `%{filename => content}`.
  """
  @spec load_stages(Path.t()) :: %{String.t() => String.t()}
  def load_stages(stages_dir) do
    case File.ls(stages_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.reduce(%{}, &put_stage_content(stages_dir, &1, &2))

      {:error, _} ->
        %{}
    end
  end

  defp put_stage_content(stages_dir, filename, acc) do
    path = Path.join(stages_dir, filename)

    case File.read(path) do
      {:ok, content} -> Map.put(acc, filename, content)
      {:error, _} -> acc
    end
  end

  @doc """
  Assembles a full prompt from loaded stages.
  Concatenates `_preamble.md` + numbered stages (00-XX) in order.
  """
  @spec assemble_prompt(%{String.t() => String.t()}) :: String.t()
  def assemble_prompt(stages) when map_size(stages) == 0, do: ""

  def assemble_prompt(stages) do
    preamble = Map.get(stages, "_preamble.md", "")

    numbered =
      stages
      |> Enum.filter(fn {name, _} -> Regex.match?(~r/^\d/, name) end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, content} -> content end)

    partials =
      stages
      |> Enum.filter(fn {name, _} ->
        String.starts_with?(name, "_") and name not in ["_preamble.md", "_continuation.md", "_retask.md"]
      end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, content} -> content end)

    [preamble | numbered ++ partials]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n---\n\n")
    |> String.trim()
  end

  @doc """
  Renders a continuation prompt from `_continuation.md` template.
  Falls back to nil if no template exists.
  """
  @spec assemble_continuation(%{String.t() => String.t()}, pos_integer(), pos_integer(), [map()]) ::
          String.t() | nil
  def assemble_continuation(stages, turn_number, max_turns, comments) do
    case Map.get(stages, "_continuation.md") do
      nil ->
        nil

      template ->
        template
        |> String.replace("{{turn_number}}", to_string(turn_number))
        |> String.replace("{{max_turns}}", to_string(max_turns))
        |> String.replace("{{comments_section}}", format_comments(comments))
    end
  end

  defp format_comments([]), do: ""

  defp format_comments(comments) do
    formatted =
      Enum.map_join(comments, "\n", fn c ->
        time = if c[:created_at], do: Calendar.strftime(c.created_at, "%H:%M UTC"), else: "?"
        "  [#{time}] #{c[:author]}: #{c[:body]}"
      end)

    """

    ## New comments on the Linear issue (from your team — read carefully and follow any instructions):
    #{formatted}

    """
  end

  @doc """
  Extracts the content section for a specific workflow phase from loaded stages.

  Phases map to stage file sections by their `SYMPHONY_PHASE: <Name>` markers.
  Returns the content from the marker through to the next marker or end of file.
  """
  @spec phase_content(%{String.t() => String.t()}, String.t()) :: String.t() | nil
  def phase_content(stages, phase_name) do
    # Search all numbered stage files for the phase name in headings
    stages
    |> Enum.filter(fn {name, _} -> Regex.match?(~r/^\d/, name) end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.reduce(nil, fn {_name, content}, acc ->
      acc || extract_phase_section(content, phase_name)
    end)
  end

  defp extract_phase_section(content, phase_name) do
    # Match phase name in ## headings (e.g. "## Step 2: Implement" matches "Implement",
    # "## Step 4: Share Evidence on Linear" matches "Share Evidence")
    normalized = String.downcase(phase_name)

    lines = String.split(content, "\n")

    case find_phase_heading(lines, normalized) do
      nil ->
        nil

      start_idx ->
        lines
        |> Enum.drop(start_idx)
        |> collect_until_next_heading()
        |> Enum.join("\n")
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end
    end
  end

  # Find the index of the first ## heading that contains the phase name as a
  # distinct term (word boundary match to avoid "Implementation" matching "Implement")
  defp find_phase_heading(lines, normalized_phase) do
    pattern = Regex.compile!("\\b#{Regex.escape(normalized_phase)}\\b", "i")

    Enum.find_index(lines, fn line ->
      String.starts_with?(line, "## ") and Regex.match?(pattern, line)
    end)
  end

  # Collect lines from a heading until the next ## heading (exclusive).
  # Fence-aware: a "## " line inside a ``` code block is content (e.g. the
  # Tester Report template), not a section boundary.
  defp collect_until_next_heading([heading | rest]) do
    {body, _in_fence} =
      Enum.reduce_while(rest, {[], false}, fn line, {acc, in_fence} ->
        cond do
          String.starts_with?(String.trim_leading(line), "```") ->
            {:cont, {[line | acc], not in_fence}}

          not in_fence and String.starts_with?(line, "## ") ->
            {:halt, {acc, in_fence}}

          true ->
            {:cont, {[line | acc], in_fence}}
        end
      end)

    [heading | Enum.reverse(body)]
  end

  defp collect_until_next_heading([]), do: []

  @doc """
  Loads the retask template from `_retask.md` in the stages directory.
  Returns nil if no template exists.
  """
  @spec load_retask_template(Path.t()) :: String.t() | nil
  def load_retask_template(stages_dir) do
    path = Path.join(stages_dir, "_retask.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  @doc """
  Computes a stamp for the stages directory based on file mtimes and hashes.
  """
  @spec directory_stamp(Path.t()) :: {:ok, term()} | {:error, term()}
  def directory_stamp(stages_dir) do
    case File.ls(stages_dir) do
      {:ok, files} ->
        md_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()

        stamps = Enum.map(md_files, &stage_file_stamp(stages_dir, &1))

        {:ok, :erlang.phash2(stamps)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stage_file_stamp(stages_dir, filename) do
    path = Path.join(stages_dir, filename)

    case File.stat(path, time: :posix) do
      {:ok, stat} -> {filename, stat.mtime, stat.size}
      {:error, _} -> {filename, 0, 0}
    end
  end
end
