defmodule SymphonyElixir.StatusOutputTest do
  # GEA-10144: on `gf-symphony` stdout is Fly's log pipe, and the status board
  # redrew itself into it about thirty lines a second. These tests hold the split
  # that fixed it — board on a terminal, log lines everywhere else — from both
  # sides, so a change that silently reinstates the board fails here.
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.LogFile
  alias SymphonyElixir.StatusOutput

  @env_var "SYMPHONY_STATUS_BOARD"

  setup do
    previous_board = System.get_env(@env_var)
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      restore_env(@env_var, previous_board)

      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      # Put both handlers back the way the application's own boot left them.
      LogFile.configure()
    end)

    :ok
  end

  describe "mode/0" do
    test "SYMPHONY_STATUS_BOARD=off keeps the log" do
      System.put_env(@env_var, "off")

      assert StatusOutput.mode() == :log
      assert StatusOutput.log?()
      refute StatusOutput.board?()
    end

    test "SYMPHONY_STATUS_BOARD=on keeps the board" do
      System.put_env(@env_var, "ON")

      assert StatusOutput.mode() == :board
      assert StatusOutput.board?()
      refute StatusOutput.log?()
    end

    test "a value that forces neither answer leaves the decision to stdout" do
      System.put_env(@env_var, "maybe")
      undecided = StatusOutput.mode()

      System.delete_env(@env_var)
      assert StatusOutput.mode() == undecided
    end

    test "stdout, not TERM, decides when nothing forces the mode" do
      # `System.cmd/3` always hands the child a pipe and never a terminal, so this
      # is the isatty arm rather than a restatement of the environment variable.
      # TERM is set to a real terminal name in both runs: on its own it must not
      # buy a board.
      elixir = System.find_executable("elixir")
      # `:code.which/1` answers `:cover_compiled` under `mix test --cover`; the
      # app's ebin directory holds the same module on disk in both runs.
      ebin = Application.app_dir(:symphony_elixir, "ebin")
      code = "IO.puts(SymphonyElixir.StatusOutput.mode())"

      unless elixir do
        flunk("elixir is not on PATH; this control arm needs a second BEAM to own a pipe")
      end

      assert {"log\n", 0} =
               System.cmd(elixir, ["-pa", ebin, "-e", code], env: [{@env_var, nil}, {"TERM", "xterm-256color"}])

      assert {"board\n", 0} =
               System.cmd(elixir, ["-pa", ebin, "-e", code], env: [{@env_var, "on"}, {"TERM", "xterm-256color"}])
    end
  end

  describe "the status board and stdout" do
    test "no escape sequence reaches stdout in log mode" do
      System.put_env(@env_var, "off")

      {output, log} =
        with_io_and_log(fn -> assert StatusDashboard.render_offline_status() == :ok end)

      assert output == ""
      refute output =~ "\e["
      assert log =~ "app_status=offline"
    end

    test "the board still draws, escapes and all, in board mode" do
      System.put_env(@env_var, "on")

      output = capture_io(fn -> assert StatusDashboard.render_offline_status() == :ok end)

      assert output =~ "SYMPHONY STATUS"
      assert output =~ "app_status=offline"
      assert output =~ IO.ANSI.clear()
      assert output =~ IO.ANSI.home()
    end
  end

  describe "LogFile.configure/0" do
    test "log mode leaves stdout to the logger, at :info and without colour" do
      System.put_env(@env_var, "off")
      Application.put_env(:symphony_elixir, :log_file, log_file_path())

      assert LogFile.configure() == :ok

      assert {:ok, %{level: :info, formatter: {Logger.Formatter, formatter}}} =
               :logger.get_handler_config(:default)

      assert formatter.colors.enabled == false
      refute List.first(formatter.template) == "\n"
    end

    test "board mode takes stdout away from the logger" do
      System.put_env(@env_var, "on")
      Application.put_env(:symphony_elixir, :log_file, log_file_path())

      assert LogFile.configure() == :ok
      assert :logger.get_handler_config(:default) == {:error, {:not_found, :default}}
    end

    test "log mode restores a console handler a previous board-mode boot removed" do
      Application.put_env(:symphony_elixir, :log_file, log_file_path())

      System.put_env(@env_var, "on")
      assert LogFile.configure() == :ok
      assert :logger.get_handler_config(:default) == {:error, {:not_found, :default}}

      System.put_env(@env_var, "off")
      assert LogFile.configure() == :ok
      assert {:ok, %{level: :info}} = :logger.get_handler_config(:default)
    end
  end

  defp log_file_path do
    Path.join(
      System.tmp_dir!(),
      "symphony-status-output-#{System.unique_integer([:positive])}/log/symphony.log"
    )
  end

  defp with_io_and_log(fun) do
    parent = self()

    output =
      capture_io(fn ->
        send(parent, {:log, ExUnit.CaptureLog.capture_log(fun)})
      end)

    receive do
      {:log, log} -> {output, log}
    after
      1_000 -> flunk("the captured log never arrived")
    end
  end
end
