defmodule Mix.Tasks.Symphony.Workflow.Preflight do
  use Mix.Task

  alias SymphonyElixir.Config.Compiler

  @moduledoc """
  Validates `WORKFLOW.md` front matter before Symphony starts polling.
  """
  @shortdoc "Preflights Symphony WORKFLOW.md config"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    paths = if args == [], do: ["WORKFLOW.md"], else: args

    Enum.each(paths, fn path ->
      expanded_path = Path.expand(path)

      case Compiler.preflight_file(expanded_path) do
        :ok ->
          Mix.shell().info("symphony.workflow.preflight: ok #{expanded_path}")

        {:error, message} ->
          Mix.raise("symphony.workflow.preflight: #{message}")
      end
    end)

    :ok
  end
end
