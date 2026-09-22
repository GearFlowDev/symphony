defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures where application logs go: always the rotating disk log, and stdout
  whenever the status board is not using it.

  Who owns stdout is the whole question (GEA-10144). On a terminal the board owns
  it — `SymphonyElixir.StatusDashboard` homes the cursor and clears the screen on
  every refresh, so a log line written between two frames is wiped before anyone
  reads it, and the console handler goes away. Down a pipe there is no board, and
  these lifecycle lines *are* the status: they stay on stdout, at `:info`, one line
  each and with no colour, which is what `fly logs` then shows.

  The disk log keeps every level in both modes.
  """

  require Logger

  alias SymphonyElixir.StatusOutput

  @handler_id :symphony_disk_log
  @default_log_relative_path "log/symphony.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  # No leading newline and no metadata: Erlang's default template opens with "\n",
  # which doubles the line count of a log nobody is reading interactively, and Fly
  # stamps its own time and instance on every line already.
  @console_format "$time [$level] $message\n"
  @console_level :info

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
  end

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        configure_console_handler(StatusOutput.mode())

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
        :ok
    end
  end

  defp configure_console_handler(:board), do: remove_default_console_handler()

  defp configure_console_handler(:log) do
    with :ok <- update_default_console_handler(:level, @console_level),
         :ok <- update_default_console_handler(:formatter, console_formatter()) do
      :ok
    else
      {:error, reason} ->
        # The disk log still has everything; say which half of the story stdout is
        # now missing rather than failing the boot over it.
        Logger.warning("Failed to configure the stdout log handler: #{inspect(reason)}")
        :ok
    end
  end

  defp update_default_console_handler(key, value) do
    case :logger.update_handler_config(:default, key, value) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> add_default_console_handler()
      {:error, reason} -> {:error, reason}
    end
  end

  # A prior `configure/0` in board mode removed it. Put back exactly what Elixir
  # boots with — `:logger_std_h` on `:standard_io` — under our own level and
  # format, so a mode flip between two calls is not a silently muted stdout.
  defp add_default_console_handler do
    :logger.add_handler(:default, :logger_std_h, %{
      level: @console_level,
      formatter: console_formatter(),
      config: %{type: :standard_io}
    })
  end

  defp console_formatter do
    Logger.Formatter.new(colors: [enabled: false], format: @console_format)
  end

  defp remove_existing_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end
