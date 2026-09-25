defmodule SymphonyElixir.Planning.AuditorCoverageTest do
  # Puts a fake `gh` first on PATH, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Planning.Auditor

  @pr_url "https://github.com/acme/widgets/pull/42"

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-auditor-cov-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    # The fake gh answers from files in `dir`. A `<kind>.exit` file makes that
    # call exit with the code it holds. Every call is appended to calls.log.
    script = """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{dir}/calls.log"
    case "$1 $2" in
      "search prs") kind=search ;;
      "api "*)
        case "$2" in
          */files) kind=files ;;
          */commits) kind=commits ;;
        esac ;;
    esac
    if [ -f "#{dir}/$kind.exit" ]; then
      echo "gh: $kind failed"
      exit "$(cat "#{dir}/$kind.exit")"
    fi
    cat "#{dir}/$kind.json"
    """

    gh = Path.join(bin, "gh")
    File.write!(gh, script)
    File.chmod!(gh, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf(dir)
    end)

    write(dir, "files", [
      %{"path" => "lib/z.ex", "additions" => 5, "deletions" => 1, "status" => "modified"},
      %{"path" => "lib/a.ex", "additions" => 10, "deletions" => 0, "status" => "added"},
      %{"path" => "lib/old.ex", "additions" => 0, "deletions" => 7, "status" => "removed"},
      %{"path" => "lib/moved.ex", "additions" => 1, "deletions" => 1, "status" => "renamed"}
    ])

    write(dir, "commits", [
      %{"sha" => "aaaa1111", "msg" => "first commit"},
      %{"sha" => "bbbb2222", "msg" => "second commit"}
    ])

    %{dir: dir, old_path: old_path}
  end

  defp write(dir, kind, data), do: File.write!(Path.join(dir, "#{kind}.json"), Jason.encode!(data))
  defp fail(dir, kind, code), do: File.write!(Path.join(dir, "#{kind}.exit"), Integer.to_string(code))
  defp calls(dir), do: dir |> Path.join("calls.log") |> File.read!() |> String.split("\n", trim: true)

  test "summarizes the PR's files and commits when given its URL", %{dir: dir} do
    assert {:ok, summary} = Auditor.audit(%{identifier: "GEA-1"}, pr_url: @pr_url)

    assert summary =~ "PR `acme/widgets#PR#42` exists with prior work"
    assert summary =~ "## Files changed (4)"
    assert summary =~ "## Commits (2; newest first)"

    # Files sort by path and carry a status marker.
    assert summary =~
             "  + lib/a.ex (+10/-0)\n  ~ lib/moved.ex (+1/-1)\n  - lib/old.ex (+0/-7)\n    lib/z.ex (+5/-1)"

    # Commits print newest first.
    assert summary =~ "  bbbb2222 second commit\n  aaaa1111 first commit"

    assert [files_call, commits_call] = calls(dir)
    assert files_call =~ "api repos/acme/widgets/pulls/42/files --paginate"
    assert commits_call =~ "api repos/acme/widgets/pulls/42/commits --paginate"
  end

  test "finds the open PR by the issue identifier when no URL is given", %{dir: dir} do
    write(dir, "search", [%{"url" => @pr_url}, %{"url" => "https://github.com/acme/other/pull/1"}])

    assert {:ok, summary} = Auditor.audit(%{"identifier" => "GEA-7"})
    assert summary =~ "acme/widgets#PR#42"
    assert hd(calls(dir)) == "search prs --state=open --json=url --match=title,body GEA-7"
  end

  test "returns no audit when the search finds no PR", %{dir: dir} do
    write(dir, "search", [])
    assert {:ok, nil} = Auditor.audit(%{identifier: "GEA-8"})
  end

  test "returns no audit when the search itself fails", %{dir: dir} do
    fail(dir, "search", 1)
    assert {:ok, nil} = Auditor.audit(%{identifier: "GEA-9"})
  end

  test "returns no audit and calls nothing for an issue without an identifier", %{dir: dir} do
    assert {:ok, nil} = Auditor.audit(%{title: "no id"})
    refute File.exists?(Path.join(dir, "calls.log"))
  end

  test "rejects a URL that is not a GitHub pull request" do
    url = "https://gitlab.com/acme/widgets/merge_requests/3"
    assert {:error, {:bad_pr_url, ^url}} = Auditor.audit(%{}, pr_url: url)
  end

  test "reports a failing gh call with its exit code and output", %{dir: dir} do
    fail(dir, "commits", 4)

    assert {:error, {:gh_failed, 4, output}} = Auditor.audit(%{}, pr_url: @pr_url)
    assert output =~ "gh: commits failed"
  end

  test "turns unparseable gh output into an error instead of a crash", %{dir: dir} do
    File.write!(Path.join(dir, "files.json"), "not json")

    log =
      capture_log(fn ->
        assert {:error, {:auditor_crash, _message}} = Auditor.audit(%{}, pr_url: @pr_url)
      end)

    assert log =~ "Auditor crashed"
  end
end
