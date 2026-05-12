import Config

if System.get_env("RELEASE_NAME") do
  workflow_path =
    System.get_env("SYMPHONY_WORKFLOW_PATH") ||
      raise """
      SYMPHONY_WORKFLOW_PATH must be set when running the Symphony release.
      Set it in the launchd plist or shell env to the absolute path of WORKFLOW.md.
      """

  unless File.regular?(workflow_path) do
    raise "SYMPHONY_WORKFLOW_PATH does not point to a regular file: #{workflow_path}"
  end

  config :symphony_elixir, :workflow_file_path, workflow_path

  if logs_root = System.get_env("SYMPHONY_LOGS_ROOT") do
    config :symphony_elixir,
           :log_file,
           SymphonyElixir.LogFile.default_log_file(Path.expand(logs_root))
  end

  if port_env = System.get_env("SYMPHONY_PORT") do
    case Integer.parse(port_env) do
      {port, ""} when port >= 0 ->
        config :symphony_elixir, :server_port_override, port

      _ ->
        raise "SYMPHONY_PORT must be a non-negative integer, got: #{inspect(port_env)}"
    end
  end
end
