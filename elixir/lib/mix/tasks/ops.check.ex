defmodule Mix.Tasks.Ops.Check do
  @moduledoc """
  Checks the guarded activation contract for the optional `symphony-ops` chain.
  """
  @shortdoc "Validates symphony-ops activation and two-phase apply guard"

  use Mix.Task

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @label "com.sazo.symphony.symphony-ops"
  @ops_label "agt1-ready-for-ops"
  @apply_ack "I understand this mutates live Symphony ops"
  @switches [
    decision: :string,
    phase: :string,
    manifest_dir: :string,
    live_dir: :string,
    workflow: :string,
    apply_ack: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_options!(invalid)

    decision = Keyword.get(opts, :decision, "disabled")
    phase = Keyword.get(opts, :phase, "plan")
    manifest_dir = Path.expand(Keyword.get(opts, :manifest_dir, "deploy/launchd"))
    live_dir = Path.expand(Keyword.get(opts, :live_dir, Path.join(System.user_home!(), "Library/LaunchAgents")))
    workflow_path = Keyword.get(opts, :workflow)

    errors =
      []
      |> validate_decision(decision)
      |> validate_phase(phase)
      |> validate_disabled_live_absence(decision, live_dir)
      |> validate_enabled_manifest(decision, manifest_dir, live_dir)
      |> validate_ops_workflow(decision, workflow_path)
      |> validate_apply_ack(phase, Keyword.get(opts, :apply_ack))

    if errors == [] do
      Mix.shell().info("ops.check: ok decision=#{decision} phase=#{phase} label=#{@label}")
      :ok
    else
      Enum.each(errors, fn error -> Mix.shell().error(error) end)
      Mix.raise("ops.check failed with #{length(errors)} issue(s)")
    end
  end

  defp validate_options!(invalid) do
    if invalid != [] do
      Mix.raise("ops.check received invalid option(s): #{inspect(invalid)}")
    end
  end

  defp validate_decision(errors, decision) when decision in ["enabled", "disabled"], do: errors
  defp validate_decision(errors, decision), do: ["invalid decision=#{inspect(decision)}; expected enabled or disabled" | errors]

  defp validate_phase(errors, phase) when phase in ["plan", "apply"], do: errors
  defp validate_phase(errors, phase), do: ["invalid phase=#{inspect(phase)}; expected plan or apply" | errors]

  defp validate_disabled_live_absence(errors, "disabled", live_dir) do
    if plist_label_exists?(live_dir, @label) do
      ["symphony-ops decision=disabled but live launchd plist exists: #{@label}" | errors]
    else
      errors
    end
  end

  defp validate_disabled_live_absence(errors, _decision, _live_dir), do: errors

  defp validate_enabled_manifest(errors, "enabled", manifest_dir, live_dir) do
    errors
    |> require_plist(manifest_dir, "manifest")
    |> require_plist(live_dir, "live")
  end

  defp validate_enabled_manifest(errors, _decision, _manifest_dir, _live_dir), do: errors

  defp require_plist(errors, dir, kind) do
    if plist_label_exists?(dir, @label) do
      errors
    else
      ["symphony-ops decision=enabled but #{kind} launchd plist is missing: #{@label}" | errors]
    end
  end

  defp validate_ops_workflow(errors, "enabled", nil) do
    ["symphony-ops decision=enabled requires --workflow for #{@ops_label} routing check" | errors]
  end

  defp validate_ops_workflow(errors, "enabled", workflow_path) do
    with {:ok, %{config: config}} <- Workflow.load(Path.expand(workflow_path)),
         {:ok, settings} <- Schema.parse(config) do
      validate_ops_label(errors, settings)
    else
      {:error, {:invalid_workflow_config, _message} = reason} ->
        ["invalid symphony-ops workflow config: #{inspect(reason)}" | errors]

      {:error, reason} ->
        ["failed to load symphony-ops workflow: #{inspect(reason)}" | errors]
    end
  end

  defp validate_ops_workflow(errors, _decision, _workflow_path), do: errors

  defp validate_ops_label(errors, settings) do
    required_labels = settings.tracker.required_labels || []

    if @ops_label in required_labels do
      errors
    else
      ["symphony-ops workflow must require label #{@ops_label}" | errors]
    end
  end

  defp validate_apply_ack(errors, "apply", @apply_ack), do: errors

  defp validate_apply_ack(errors, "apply", _ack) do
    ["phase=apply requires --apply-ack #{@apply_ack |> inspect()}" | errors]
  end

  defp validate_apply_ack(errors, _phase, _ack), do: errors

  defp plist_label_exists?(dir, label) do
    dir
    |> Path.join("*.plist")
    |> Path.wildcard()
    |> Enum.any?(&(plist_label(&1) == label))
  end

  defp plist_label(path) do
    case System.cmd("plutil", ["-extract", "Label", "raw", "-o", "-", path], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      {_out, _code} -> nil
    end
  end
end
