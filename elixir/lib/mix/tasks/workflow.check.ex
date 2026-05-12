defmodule Mix.Tasks.Workflow.Check do
  @moduledoc """
  Validates a Symphony `WORKFLOW.md` before starting a chain.
  """
  @shortdoc "Validates WORKFLOW.md configuration and routing contract"

  use Mix.Task

  alias SymphonyElixir.{Config, Workflow}

  @switches [file: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_args!(argv, invalid)

    workflow_path =
      opts
      |> Keyword.get(:file, List.first(argv) || Workflow.workflow_file_path())
      |> Path.expand()

    Workflow.set_workflow_file_path(workflow_path)

    case Config.validate!() do
      :ok ->
        Config.settings!()
        |> success_message(workflow_path)
        |> Mix.shell().info()

        :ok

      {:error, reason} ->
        Mix.raise("workflow.check failed: #{Config.format_error(reason)}")
    end
  end

  defp validate_args!(argv, invalid) do
    cond do
      invalid != [] ->
        Mix.raise("workflow.check received invalid option(s): #{inspect(invalid)}")

      length(argv) > 1 ->
        Mix.raise("workflow.check accepts at most one workflow path")

      true ->
        :ok
    end
  end

  defp success_message(settings, workflow_path) do
    [
      "workflow.check: ok",
      "file=#{workflow_path}",
      "tracker=#{settings.tracker.kind}",
      "scope=#{scope_summary(settings.tracker)}",
      "active_states=#{length(settings.tracker.active_states)}",
      "terminal_states=#{length(settings.tracker.terminal_states)}"
    ]
    |> Enum.join(" ")
  end

  defp scope_summary(tracker) do
    cond do
      present_string?(tracker.project_slug) -> "project:#{String.trim(tracker.project_slug)}"
      present_string?(tracker.team_key) -> "team:#{String.trim(tracker.team_key)}"
      true -> "n/a"
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
