defmodule SymphonyElixir.StatusOutput do
  @moduledoc """
  Decides where Symphony's status goes: the full-screen board, or the log.

  The board is written for a terminal. It homes the cursor, clears the screen and
  redraws every row on every refresh, so it is only ever readable on a device that
  can move a cursor. Point it at a pipe and it becomes the loudest thing in the
  file: on `gf-symphony` (GEA-10144) roughly thirty lines a second of box drawing
  and `ESC[H ESC[2J` filled Fly's bounded log window, and a person reading
  `fly logs` after an incident saw the board and nothing else.

  So the device decides. A terminal gets the board. Anything else gets the log —
  `SymphonyElixir.LogFile` leaves the lifecycle lines on stdout instead, one line
  per state change, and no escape sequence is written at all. The web dashboard on
  the HTTP server's port is unchanged either way; it is the place for the board.

  `SYMPHONY_STATUS_BOARD` forces the answer: `off` keeps the log even on a
  terminal, `on` keeps the board even down a pipe.
  """

  @env_var "SYMPHONY_STATUS_BOARD"
  @off ~w(off 0 false no none)
  @on ~w(on 1 true yes force)

  @doc """
  `:board` when the status board may draw on stdout, `:log` when it may not.
  """
  @spec mode() :: :board | :log
  def mode do
    case forced_mode() do
      nil -> if terminal?(), do: :board, else: :log
      forced -> forced
    end
  end

  @doc "True when stdout belongs to the status board."
  @spec board?() :: boolean()
  def board?, do: mode() == :board

  @doc "True when stdout belongs to the log."
  @spec log?() :: boolean()
  def log?, do: mode() == :log

  @doc "The environment variable that forces the mode."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  defp forced_mode do
    case @env_var |> System.get_env("") |> String.trim() |> String.downcase() do
      value when value in @off -> :log
      value when value in @on -> :board
      _ -> nil
    end
  end

  # Ask the device the board would be written to. `:io.columns/0` asks the calling
  # process's group leader — the same device `IO.write/1` reaches — and answers
  # `{:error, :enotsup}` for anything that is not a terminal, which is the isatty
  # check. TERM only ever overrides that downward: a terminal that calls itself
  # `dumb` cannot move a cursor either.
  defp terminal? do
    match?({:ok, _columns}, :io.columns()) and System.get_env("TERM") != "dumb"
  end
end
