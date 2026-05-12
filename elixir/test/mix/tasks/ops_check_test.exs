defmodule Mix.Tasks.Ops.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SymphonyElixir.TestSupport, only: [write_workflow_file!: 1, write_workflow_file!: 2]

  alias Mix.Tasks.Ops.Check

  setup do
    Mix.Task.reenable("ops.check")

    on_exit(fn ->
      Mix.Task.reenable("ops.check")
    end)

    :ok
  end

  test "passes disabled decision when no live symphony-ops plist exists" do
    in_temp_dirs(fn manifest_dir, live_dir, workflow_path ->
      write_workflow_file!(workflow_path)

      output =
        capture_io(fn ->
          assert :ok =
                   Check.run([
                     "--decision",
                     "disabled",
                     "--manifest-dir",
                     manifest_dir,
                     "--live-dir",
                     live_dir
                   ])
        end)

      assert output =~ "ops.check: ok decision=disabled"
    end)
  end

  test "fails disabled decision when live symphony-ops plist exists" do
    in_temp_dirs(fn manifest_dir, live_dir, _workflow_path ->
      write_plist!(live_dir)

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/ops.check failed/, fn ->
          Check.run(["--decision", "disabled", "--manifest-dir", manifest_dir, "--live-dir", live_dir])
        end
      end)
    end)
  end

  test "enabled decision requires manifest live plist and ops-only routing label" do
    in_temp_dirs(fn manifest_dir, live_dir, workflow_path ->
      write_plist!(manifest_dir)
      write_plist!(live_dir)

      write_workflow_file!(workflow_path,
        tracker_required_labels: ["agt1-ready-for-ops"]
      )

      output =
        capture_io(fn ->
          assert :ok =
                   Check.run([
                     "--decision",
                     "enabled",
                     "--manifest-dir",
                     manifest_dir,
                     "--live-dir",
                     live_dir,
                     "--workflow",
                     workflow_path
                   ])
        end)

      assert output =~ "ops.check: ok decision=enabled"

      write_workflow_file!(workflow_path,
        tracker_required_labels: ["agt1-ready-for-symphony"]
      )

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/ops.check failed/, fn ->
          Check.run([
            "--decision",
            "enabled",
            "--manifest-dir",
            manifest_dir,
            "--live-dir",
            live_dir,
            "--workflow",
            workflow_path
          ])
        end
      end)
    end)
  end

  test "apply phase requires explicit acknowledgement" do
    in_temp_dirs(fn manifest_dir, live_dir, workflow_path ->
      write_plist!(manifest_dir)
      write_plist!(live_dir)

      write_workflow_file!(workflow_path,
        tracker_required_labels: ["agt1-ready-for-ops"]
      )

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/ops.check failed/, fn ->
          Check.run([
            "--decision",
            "enabled",
            "--phase",
            "apply",
            "--manifest-dir",
            manifest_dir,
            "--live-dir",
            live_dir,
            "--workflow",
            workflow_path
          ])
        end
      end)

      output =
        capture_io(fn ->
          assert :ok =
                   Check.run([
                     "--decision",
                     "enabled",
                     "--phase",
                     "apply",
                     "--manifest-dir",
                     manifest_dir,
                     "--live-dir",
                     live_dir,
                     "--workflow",
                     workflow_path,
                     "--apply-ack",
                     "I understand this mutates live Symphony ops"
                   ])
        end)

      assert output =~ "phase=apply"
    end)
  end

  defp in_temp_dirs(fun) do
    root = Path.join(System.tmp_dir!(), "ops-check-test-#{System.unique_integer([:positive, :monotonic])}")
    manifest_dir = Path.join(root, "manifest")
    live_dir = Path.join(root, "live")
    workflow_path = Path.join(root, "WORKFLOW.md")

    File.mkdir_p!(manifest_dir)
    File.mkdir_p!(live_dir)

    try do
      fun.(manifest_dir, live_dir, workflow_path)
    after
      File.rm_rf(root)
    end
  end

  defp write_plist!(dir) do
    File.write!(Path.join(dir, "com.sazo.symphony.symphony-ops.plist"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.sazo.symphony.symphony-ops</string>
    </dict>
    </plist>
    """)
  end
end
