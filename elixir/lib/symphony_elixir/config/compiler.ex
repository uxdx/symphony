defmodule SymphonyElixir.Config.Compiler do
  @moduledoc """
  Compile-time contract checks for `WORKFLOW.md` front matter.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @type compile_result :: {:ok, Schema.t()} | {:error, String.t()}

  @allowed_keys %{
    [] => ~w(agent claude codex hooks observability polling server tracker worker workspace),
    ["claude"] => ~w(command permission_mode turn_timeout_ms),
    ["agent"] => ~w(backend max_concurrent_agents max_concurrent_agents_by_state max_retry_attempts max_retry_backoff_ms max_turns),
    ["codex"] => ~w(approval_policy command read_timeout_ms stall_timeout_ms thread_sandbox turn_sandbox_policy turn_timeout_ms),
    ["hooks"] => ~w(after_create after_run before_remove before_run timeout_ms),
    ["observability"] => ~w(dashboard_enabled refresh_ms render_interval_ms),
    ["polling"] => ~w(interval_ms),
    ["server"] => ~w(host port),
    ["tracker"] => ~w(active_states api_key assignee endpoint exclude_labels kind project_slug required_labels team_key terminal_states),
    ["worker"] => ~w(max_concurrent_agents_per_host ssh_hosts),
    ["workspace"] => ~w(root)
  }

  @spec compile_file(Path.t()) :: compile_result()
  def compile_file(path) when is_binary(path) do
    chain = chain_name(path)

    with {:ok, %{config: config}} <- Workflow.load(path),
         :ok <- reject_unknown_fields(config, chain),
         {:ok, settings} <- parse_schema(config, chain),
         :ok <- validate_semantics(settings, chain) do
      {:ok, settings}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, format_load_error(chain, reason)}
    end
  end

  @spec preflight_file(Path.t()) :: :ok | {:error, String.t()}
  def preflight_file(path) when is_binary(path) do
    case compile_file(path) do
      {:ok, _settings} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @spec compile_config(map(), String.t()) :: compile_result()
  def compile_config(config, chain) when is_map(config) and is_binary(chain) do
    with :ok <- reject_unknown_fields(config, chain),
         {:ok, settings} <- parse_schema(config, chain),
         :ok <- validate_semantics(settings, chain) do
      {:ok, settings}
    end
  end

  defp reject_unknown_fields(config, chain) do
    case unknown_fields(normalize_keys(config)) do
      [] -> :ok
      [field | _rest] -> {:error, contract_error(chain, field, "unknown field")}
    end
  end

  defp unknown_fields(config) when is_map(config), do: collect_unknown_fields(config, [])

  defp collect_unknown_fields(value, path) when is_map(value) do
    allowed = Map.get(@allowed_keys, path)

    cond do
      is_nil(allowed) ->
        []

      true ->
        value
        |> Enum.flat_map(fn {key, nested_value} ->
          key = to_string(key)
          next_path = path ++ [key]

          if key in allowed do
            collect_unknown_fields(nested_value, next_path)
          else
            [Enum.join(next_path, ".")]
          end
        end)
        |> Enum.sort()
    end
  end

  defp collect_unknown_fields(_value, _path), do: []

  defp parse_schema(config, chain) do
    case Schema.parse(config) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, {:invalid_workflow_config, message}} ->
        {:error, contract_error(chain, schema_field(message), message)}

      {:error, reason} ->
        {:error, contract_error(chain, "workflow", inspect(reason))}
    end
  end

  defp validate_semantics(settings, chain) do
    cond do
      blank?(settings.tracker.kind) ->
        {:error, contract_error(chain, "tracker.kind", "required field is missing")}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, contract_error(chain, "tracker.kind", "unsupported tracker kind #{inspect(settings.tracker.kind)}")}

      settings.tracker.kind == "linear" and blank?(settings.tracker.api_key) ->
        {:error, contract_error(chain, "tracker.api_key", "required field is missing")}

      settings.tracker.kind == "linear" and locator_count(settings.tracker) != 1 ->
        {:error, contract_error(chain, "tracker.project_slug/team_key", "set exactly one Linear locator")}

      state_overlap(settings.tracker.active_states, settings.tracker.terminal_states) != [] ->
        overlap = settings.tracker.active_states |> state_overlap(settings.tracker.terminal_states) |> Enum.join(", ")
        {:error, contract_error(chain, "tracker.active_states/terminal_states", "states overlap: #{overlap}")}

      label_overlap(settings.tracker.required_labels, settings.tracker.exclude_labels) != [] ->
        overlap =
          settings.tracker.required_labels
          |> label_overlap(settings.tracker.exclude_labels)
          |> Enum.join(", ")

        {:error, contract_error(chain, "tracker.required_labels/exclude_labels", "labels overlap: #{overlap}")}

      settings.agent.backend not in ["codex", "claude"] ->
        {:error, contract_error(chain, "agent.backend", "unsupported backend #{inspect(settings.agent.backend)}")}

      settings.agent.backend == "codex" and blank?(settings.codex.command) ->
        {:error, contract_error(chain, "codex.command", "required for codex backend")}

      settings.agent.backend == "claude" and blank?(settings.claude.command) ->
        {:error, contract_error(chain, "claude.command", "required for claude backend")}

      true ->
        :ok
    end
  end

  defp locator_count(tracker) do
    [tracker.project_slug, tracker.team_key]
    |> Enum.count(&(not blank?(&1)))
  end

  defp state_overlap(active_states, terminal_states) do
    active = normalized_set(active_states)
    terminal = normalized_set(terminal_states)

    active
    |> MapSet.intersection(terminal)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp label_overlap(required_labels, exclude_labels) do
    required = normalized_set(required_labels)
    excluded = normalized_set(exclude_labels)

    required
    |> MapSet.intersection(excluded)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp normalized_set(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp normalized_set(_values), do: MapSet.new()

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp schema_field(message) do
    message
    |> String.split(" ", parts: 2)
    |> List.first()
  end

  defp format_load_error(chain, {:missing_workflow_file, path, reason}) do
    contract_error(chain, "workflow", "file not found at #{path}: #{inspect(reason)}")
  end

  defp format_load_error(chain, {:workflow_parse_error, reason}) do
    contract_error(chain, "workflow", "front matter parse failed: #{inspect(reason)}")
  end

  defp format_load_error(chain, :workflow_front_matter_not_a_map) do
    contract_error(chain, "workflow", "front matter must decode to a map")
  end

  defp format_load_error(chain, reason) do
    contract_error(chain, "workflow", inspect(reason))
  end

  defp contract_error(chain, field, message) do
    "[#{chain}] #{field}: #{message}"
  end

  defp chain_name(path) do
    expanded = Path.expand(path)
    basename = Path.basename(expanded)

    if basename == "WORKFLOW.md" do
      expanded |> Path.dirname() |> Path.basename()
    else
      Path.rootname(basename)
    end
  end
end
