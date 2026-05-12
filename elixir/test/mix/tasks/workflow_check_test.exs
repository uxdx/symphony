defmodule Mix.Tasks.Workflow.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SymphonyElixir.TestSupport, only: [write_workflow_file!: 2]

  alias Mix.Tasks.Workflow.Check
  alias SymphonyElixir.Workflow

  setup do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    Mix.Task.reenable("workflow.check")

    on_exit(fn ->
      case original_workflow_path do
        nil -> Application.delete_env(:symphony_elixir, :workflow_file_path)
        path -> Application.put_env(:symphony_elixir, :workflow_file_path, path)
      end

      Mix.Task.reenable("workflow.check")
    end)

    :ok
  end

  test "validates a team-scoped workflow" do
    with_temp_workflow(fn workflow_path ->
      write_workflow_file!(workflow_path,
        tracker_project_slug: nil,
        tracker_team_key: "AGT1",
        tracker_required_labels: ["Ready"],
        tracker_exclude_labels: ["Needs Human"]
      )

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--file", workflow_path])
        end)

      assert output =~ "workflow.check: ok"
      assert output =~ "scope=team:AGT1"
      assert output =~ "active_states=2"
    end)
  end

  test "fails when a linear workflow has no project or team scope" do
    with_temp_workflow(fn workflow_path ->
      write_workflow_file!(workflow_path,
        tracker_project_slug: nil,
        tracker_team_key: nil
      )

      assert_raise Mix.Error, ~r/set tracker.project_slug or tracker.team_key/, fn ->
        Check.run(["--file", workflow_path])
      end
    end)
  end

  defp with_temp_workflow(fun) do
    root = Path.join(System.tmp_dir!(), "workflow-check-task-test-#{System.unique_integer([:positive, :monotonic])}")
    workflow_path = Path.join(root, "WORKFLOW.md")

    File.mkdir_p!(root)

    try do
      Workflow.set_workflow_file_path(workflow_path)
      fun.(workflow_path)
    after
      File.rm_rf(root)
    end
  end
end
