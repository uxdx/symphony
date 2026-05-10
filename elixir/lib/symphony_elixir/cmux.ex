defmodule SymphonyElixir.Cmux do
  @moduledoc """
  Low-level wrapper around the `sazo-slave` CLI.

  Three operations: `ensure_lane/3` (boot or reuse a long-lived chain pane),
  `run_turn/2` (dispatch a single turn into the pane via `sazo-slave run-turn`),
  `close_lane/1` (teardown).

  PR2 scope is read-only: callers MUST NOT issue Linear mutations from
  `cmd_body`. claim/fence enforcement is deferred to PR3.
  """

  require Logger

  @sazo_slave_default "sazo-slave"

  @type lane_name :: String.t()
  @type lane_info :: %{lane: String.t(), surface: String.t() | nil, raw: String.t()}

  @spec sazo_slave_bin() :: String.t()
  def sazo_slave_bin do
    System.get_env("SAZO_SLAVE_BIN") || @sazo_slave_default
  end

  @doc """
  Return existing lane state if a slave with id `symphony-<lane>` is alive,
  otherwise spawn a new one.
  """
  @spec ensure_lane(lane_name(), Path.t(), keyword()) ::
          {:ok, lane_info()} | {:error, term()}
  def ensure_lane(lane, workspace, opts \\ []) do
    case lane_state(lane) do
      {:ok, lane_map} -> {:ok, lane_map}
      {:error, :not_found} -> spawn_lane(lane, workspace, opts)
    end
  end

  @doc """
  Dispatch a turn into the lane pane. The `cmd_body` is written to a tmp file
  with mode 0700 and passed to `sazo-slave run-turn --cmd-file`. The wrapper
  inside sazo-slave guarantees nonce-validated sentinel + exit-code passthrough.

  Returns `{:ok, raw_stdout}` on exit 0, otherwise a tagged error matching the
  PR1 exit-code contract: 124=timeout, 125=sentinel_missing, 126=nonce_mismatch.
  """
  @spec run_turn(lane_name(), keyword()) ::
          {:ok, String.t()}
          | {:error, :turn_timeout}
          | {:error, :sentinel_missing}
          | {:error, {:nonce_mismatch, String.t()}}
          | {:error, {:turn_failed, integer(), String.t()}}
  def run_turn(lane, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    turn_id = Keyword.fetch!(opts, :turn_id)
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    cmd_body = Keyword.fetch!(opts, :cmd_body)
    timeout = Keyword.get(opts, :timeout, 3600)
    cmd_file = write_temp_cmd(turn_id, cmd_body)

    try do
      case System.cmd(sazo_slave_bin(), [
             "run-turn",
             "symphony-#{lane}",
             "--workspace",
             workspace,
             "--lane",
             lane,
             "--turn-id",
             turn_id,
             "--attempt-id",
             to_string(attempt_id),
             "--cmd-file",
             cmd_file,
             "--timeout",
             to_string(timeout)
           ], stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {_, 124} -> {:error, :turn_timeout}
        {_, 125} -> {:error, :sentinel_missing}
        {out, 126} -> {:error, {:nonce_mismatch, out}}
        {out, code} -> {:error, {:turn_failed, code, out}}
      end
    after
      _ = File.rm(cmd_file)
    end
  end

  @doc "Close the lane pane (issue `sazo-slave close symphony-<lane>`)."
  @spec close_lane(lane_name()) :: :ok
  def close_lane(lane) do
    {_out, _code} =
      System.cmd(sazo_slave_bin(), ["close", "symphony-#{lane}"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp spawn_lane(lane, workspace, opts) do
    agent = Keyword.get(opts, :agent, "claude")
    title = Keyword.get(opts, :title, "[symphony:#{lane}]")

    args =
      [
        "new",
        "symphony-#{lane}",
        agent,
        "--symphony",
        "--lane",
        lane,
        "--cwd",
        workspace,
        "--title",
        title
      ]

    case System.cmd(sazo_slave_bin(), args, stderr_to_stdout: true) do
      {out, 0} -> parse_lane(lane, out)
      {out, code} -> {:error, {:spawn_failed, code, out}}
    end
  end

  @doc false
  def parse_lane(lane, out) do
    surface =
      case Regex.run(~r/surface=(surface:\d+|[A-F0-9-]{36})/i, out) do
        [_, s] -> s
        _ -> nil
      end

    {:ok, %{lane: lane, surface: surface, raw: out}}
  end

  defp lane_state(lane) do
    state_file =
      Path.expand("~/.sazo/slaves/state/symphony-#{lane}.json")

    case File.read(state_file) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            {:ok,
             %{
               lane: lane,
               surface: Map.get(decoded, "surface_uuid") || Map.get(decoded, "surface_ref"),
               raw: raw
             }}

          {:error, _} ->
            {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp write_temp_cmd(turn_id, body) do
    safe_id = String.replace(turn_id, ~r/[^A-Za-z0-9._-]/, "_")
    path = Path.join(System.tmp_dir!(), "symphony-#{safe_id}.sh")
    File.write!(path, body)
    File.chmod!(path, 0o700)
    path
  end
end
