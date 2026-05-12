defmodule Mix.Tasks.Launchd.Check do
  @moduledoc """
  Compares repository launchd manifests with a live LaunchAgents directory.
  """
  @shortdoc "Reports Symphony launchd manifest/live drift"

  use Mix.Task

  @switches [manifest_dir: :string, live_dir: :string, allow_live_only: :keep]
  @label_prefix "com.sazo.symphony."
  @compared_fields [
    :program_arguments,
    :working_directory,
    :chain_name,
    :workflow_path,
    :throttle_interval,
    :start_interval
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_options!(invalid)

    manifest_dir = Path.expand(Keyword.get(opts, :manifest_dir, "deploy/launchd"))
    live_dir = Path.expand(Keyword.get(opts, :live_dir, Path.join(System.user_home!(), "Library/LaunchAgents")))
    allowed_live_only = opts |> Keyword.get_values(:allow_live_only) |> MapSet.new()

    manifest = inventory(manifest_dir)
    live = inventory(live_dir)
    errors = drift_errors(manifest, live, allowed_live_only)

    if errors == [] do
      Mix.shell().info("launchd.check: ok manifest=#{manifest_dir} live=#{live_dir} labels=#{map_size(manifest)}")
      :ok
    else
      Enum.each(errors, fn error -> Mix.shell().error(error) end)
      Mix.raise("launchd.check failed with #{length(errors)} issue(s)")
    end
  end

  defp validate_options!(invalid) do
    if invalid != [] do
      Mix.raise("launchd.check received invalid option(s): #{inspect(invalid)}")
    end
  end

  defp inventory(dir) do
    dir
    |> Path.join("*.plist")
    |> Path.wildcard()
    |> Enum.flat_map(&plist_entry/1)
    |> Map.new(fn entry -> {entry.label, entry} end)
  end

  defp plist_entry(path) do
    case plist_raw(path, "Label") do
      label when is_binary(label) ->
        if String.starts_with?(label, @label_prefix) do
          [
            %{
              label: label,
              path: path,
              program_arguments: plist_json(path, "ProgramArguments") || [],
              working_directory: plist_raw(path, "WorkingDirectory"),
              chain_name: plist_json(path, "EnvironmentVariables") |> env_value("SYMPHONY_CHAIN_NAME"),
              workflow_path: plist_json(path, "EnvironmentVariables") |> env_value("SYMPHONY_WORKFLOW_PATH"),
              throttle_interval: plist_raw(path, "ThrottleInterval"),
              start_interval: plist_raw(path, "StartInterval")
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp drift_errors(manifest, live, allowed_live_only) do
    manifest_labels = Map.keys(manifest) |> MapSet.new()
    live_labels = Map.keys(live) |> MapSet.new()

    missing_live =
      manifest_labels
      |> MapSet.difference(live_labels)
      |> MapSet.to_list()
      |> Enum.map(&"missing live launchd plist: #{&1}")

    live_only =
      live_labels
      |> MapSet.difference(manifest_labels)
      |> MapSet.difference(allowed_live_only)
      |> MapSet.to_list()
      |> Enum.map(&"live-only launchd plist is undocumented: #{&1}")

    field_drift =
      manifest_labels
      |> MapSet.intersection(live_labels)
      |> MapSet.to_list()
      |> Enum.flat_map(fn label -> field_drift_errors(label, Map.fetch!(manifest, label), Map.fetch!(live, label)) end)

    missing_live ++ live_only ++ field_drift
  end

  defp field_drift_errors(label, manifest, live) do
    @compared_fields
    |> Enum.flat_map(fn field ->
      manifest_value = Map.get(manifest, field)
      live_value = Map.get(live, field)

      if manifest_value == live_value do
        []
      else
        ["launchd drift #{label} #{field}: manifest=#{inspect(manifest_value)} live=#{inspect(live_value)}"]
      end
    end)
  end

  defp plist_raw(path, key_path) do
    case System.cmd("plutil", ["-extract", key_path, "raw", "-o", "-", path], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      {_out, _code} -> nil
    end
  end

  defp plist_json(path, key_path) do
    case System.cmd("plutil", ["-extract", key_path, "json", "-o", "-", path], stderr_to_stdout: true) do
      {value, 0} ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          {:error, _reason} -> nil
        end

      {_out, _code} ->
        nil
    end
  end

  defp env_value(%{} = env, key), do: Map.get(env, key)
  defp env_value(_env, _key), do: nil
end
