defmodule Mix.Tasks.Launchd.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Launchd.Check

  setup do
    Mix.Task.reenable("launchd.check")

    on_exit(fn ->
      Mix.Task.reenable("launchd.check")
    end)

    :ok
  end

  test "passes when manifest and live launchd inventories match" do
    in_temp_dirs(fn manifest_dir, live_dir ->
      write_plist!(manifest_dir, "com.sazo.symphony.todo-code")
      write_plist!(live_dir, "com.sazo.symphony.todo-code")

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--manifest-dir", manifest_dir, "--live-dir", live_dir])
        end)

      assert output =~ "launchd.check: ok"
      assert output =~ "labels=1"
    end)
  end

  test "fails for undocumented live-only launchd plists" do
    in_temp_dirs(fn manifest_dir, live_dir ->
      write_plist!(manifest_dir, "com.sazo.symphony.todo-code")
      write_plist!(live_dir, "com.sazo.symphony.todo-code")
      write_plist!(live_dir, "com.sazo.symphony.workspace-cleanup")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/launchd.check failed/, fn ->
          Check.run(["--manifest-dir", manifest_dir, "--live-dir", live_dir])
        end
      end)

      output =
        capture_io(fn ->
          assert :ok =
                   Check.run([
                     "--manifest-dir",
                     manifest_dir,
                     "--live-dir",
                     live_dir,
                     "--allow-live-only",
                     "com.sazo.symphony.workspace-cleanup"
                   ])
        end)

      assert output =~ "launchd.check: ok"
    end)
  end

  test "fails when a documented live plist drifts from the manifest" do
    in_temp_dirs(fn manifest_dir, live_dir ->
      write_plist!(manifest_dir, "com.sazo.symphony.todo-code", workflow_path: "/workflows/todo/WORKFLOW.md")
      write_plist!(live_dir, "com.sazo.symphony.todo-code", workflow_path: "/workflows/other/WORKFLOW.md")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/launchd.check failed/, fn ->
          Check.run(["--manifest-dir", manifest_dir, "--live-dir", live_dir])
        end
      end)
    end)
  end

  defp in_temp_dirs(fun) do
    root = Path.join(System.tmp_dir!(), "launchd-check-test-#{System.unique_integer([:positive, :monotonic])}")
    manifest_dir = Path.join(root, "manifest")
    live_dir = Path.join(root, "live")

    File.mkdir_p!(manifest_dir)
    File.mkdir_p!(live_dir)

    try do
      fun.(manifest_dir, live_dir)
    after
      File.rm_rf(root)
    end
  end

  defp write_plist!(dir, label, opts \\ []) do
    chain_name = Keyword.get(opts, :chain_name, String.replace_prefix(label, "com.sazo.symphony.", ""))
    workflow_path = Keyword.get(opts, :workflow_path, "/workflows/#{chain_name}/WORKFLOW.md")
    working_directory = Keyword.get(opts, :working_directory, "/repo/elixir")
    command = Keyword.get(opts, :command, "cd /repo/elixir && exec _build/prod/rel/symphony/bin/symphony start")
    throttle_interval = Keyword.get(opts, :throttle_interval, 30)

    File.write!(Path.join(dir, "#{label}.plist"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{xml(label)}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>#{xml(command)}</string>
      </array>
      <key>WorkingDirectory</key>
      <string>#{xml(working_directory)}</string>
      <key>ThrottleInterval</key>
      <integer>#{throttle_interval}</integer>
      <key>EnvironmentVariables</key>
      <dict>
        <key>SYMPHONY_CHAIN_NAME</key>
        <string>#{xml(chain_name)}</string>
        <key>SYMPHONY_WORKFLOW_PATH</key>
        <string>#{xml(workflow_path)}</string>
      </dict>
    </dict>
    </plist>
    """)
  end

  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
