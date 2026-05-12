defmodule SymphonyElixir.StateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.State

  test "refuses to create the runtime DB inside the current git checkout" do
    test_root = Path.join(System.tmp_dir!(), "symphony-state-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    System.cmd("git", ["-C", test_root, "init", "-b", "main"])

    previous_cwd = File.cwd!()
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      File.cd!(test_root)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               State.start_link(name: :repo_state_db_test, db_path: Path.join(test_root, "state.db"))

      assert message =~ "must not be inside the repository checkout"
    after
      Process.flag(:trap_exit, previous_trap_exit)
      File.cd!(previous_cwd)
      File.rm_rf!(test_root)
    end
  end
end
