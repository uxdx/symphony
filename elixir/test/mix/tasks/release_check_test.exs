defmodule Mix.Tasks.Release.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Release.Check

  setup do
    Mix.Task.reenable("release.check")

    on_exit(fn ->
      Mix.Task.reenable("release.check")
    end)

    :ok
  end

  test "passes for a clean checkout whose pin matches HEAD" do
    in_temp_git_repo(fn repo_root ->
      head = git!(repo_root, ["rev-parse", "HEAD"])
      pin = String.slice(head, 0, 7)

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--repo-root", repo_root, "--pin", pin])
        end)

      assert output =~ "release.check: ok"
      assert output =~ "pin=#{pin}"
      assert output =~ "dirty=no"
    end)
  end

  test "fails for dirty checkout unless explicitly overridden" do
    in_temp_git_repo(fn repo_root ->
      File.write!(Path.join(repo_root, "dirty.txt"), "uncommitted\n")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/release.check failed/, fn ->
          Check.run(["--repo-root", repo_root])
        end
      end)

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--repo-root", repo_root, "--allow-dirty"])
        end)

      assert output =~ "dirty=allowed"
    end)
  end

  test "fails when release pin does not match HEAD" do
    in_temp_git_repo(fn repo_root ->
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/release.check failed/, fn ->
          Check.run(["--repo-root", repo_root, "--pin", "0000000"])
        end
      end)
    end)
  end

  test "fails when built release commit does not match expected commit" do
    in_temp_git_repo(fn repo_root ->
      built_commit_file = Path.join(repo_root, ".git/built-release-commit")
      File.write!(built_commit_file, "0000000\n")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/release.check failed/, fn ->
          Check.run(["--repo-root", repo_root, "--built-commit-file", built_commit_file])
        end
      end)

      head = git!(repo_root, ["rev-parse", "HEAD"])
      File.write!(built_commit_file, head <> "\n")

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--repo-root", repo_root, "--built-commit-file", built_commit_file])
        end)

      assert output =~ "built_release_commit=#{head}"
    end)
  end

  test "fails when runtime state database files are inside the checkout" do
    in_temp_git_repo(fn repo_root ->
      File.write!(Path.join(repo_root, "state.db"), "")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/release.check failed/, fn ->
          Check.run(["--repo-root", repo_root, "--allow-dirty"])
        end
      end)
    end)
  end

  defp in_temp_git_repo(fun) do
    repo_root = Path.join(System.tmp_dir!(), "release-check-test-#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(repo_root)
    File.mkdir_p!(repo_root)

    try do
      git!(repo_root, ["init", "-b", "main"])
      git!(repo_root, ["config", "user.name", "Test User"])
      git!(repo_root, ["config", "user.email", "test@example.com"])
      File.write!(Path.join(repo_root, "README.md"), "release check\n")
      git!(repo_root, ["add", "README.md"])
      git!(repo_root, ["commit", "-m", "initial"])
      fun.(repo_root)
    after
      File.rm_rf(repo_root)
    end
  end

  defp git!(repo_root, args) do
    case System.cmd("git", ["-C", repo_root | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{out}")
    end
  end
end
