defmodule SymphonyElixir.Claude.CmuxPrintBackend do
  @moduledoc """
  PR2 read-only backend. Wires `claude --print --output-format stream-json`
  through `SymphonyElixir.Cmux` (sazo-slave run-turn) so credentials read
  from the macOS keychain succeed (login-keychain unlocked inside the cmux
  pane shell).

  PR2 contract — `dry_run_only: true` is enforced:

    * **No** Linear mutations from `cmd_body` (the prompt may instruct the
      agent to analyse only — Linear writes are gated by `sazo-linear-mutate`
      arriving in PR3 and are not invoked from this module).
    * **No** state-machine claim/fence (Issues.upsert/begin_turn/fail_turn
      live in Step 6 / PR3+ and are not called).
    * **No** retry/throttle/realm-pause logic. classify_error/rate_limit
      handling lands in PR3 once `Issues` + `RateLimiter` exist.

  The only behaviour kept from STEP-3 §3 is the happy path (parse + summarize)
  plus error tagging passed back to the caller verbatim. G-PR2 verifies the
  Linear-mutate-counter == 0 guarantee from outside this module.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Cmux
  alias SymphonyElixir.Agent.StreamJsonParser

  require Logger

  @impl true
  def start_session(workspace, opts) do
    chain = Keyword.fetch!(opts, :chain_name)

    case Cmux.ensure_lane(chain, workspace, agent: "shell") do
      {:ok, lane} ->
        session = %{
          chain: chain,
          lane: lane,
          workspace: workspace,
          session_id: Keyword.get(opts, :session_id)
        }

        {:ok, session}

      {:error, reason} ->
        {:error, {:lane_spawn_failed, reason}}
    end
  end

  @impl true
  def run_turn(%{chain: chain, workspace: workspace} = session, prompt, issue, opts)
      when is_binary(prompt) do
    turn_id = Keyword.get(opts, :turn_id) || generate_turn_id(issue)
    attempt_id = Keyword.get(opts, :attempt_id, 1)
    timeout = Keyword.get(opts, :turn_timeout, 3600)

    {cmd_body, prompt_path} = build_claude_print_cmd(session, prompt, opts)

    try do
      case Cmux.run_turn(chain,
             workspace: workspace,
             turn_id: turn_id,
             attempt_id: attempt_id,
             cmd_body: cmd_body,
             timeout: timeout
           ) do
        {:ok, raw_stdout} ->
          on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
          events = StreamJsonParser.parse(raw_stdout)
          Enum.each(events, on_message)

          summary = StreamJsonParser.summarize(events)
          new_sid = summary[:session_id] || session.session_id
          new_session = %{session | session_id: new_sid}

          {:ok, Map.put(summary, :session_id, new_sid), new_session}

        {:error, reason} ->
          Logger.warning("[claude_cmux] run_turn error: #{inspect(reason)} chain=#{chain}")
          {:error, reason}
      end
    after
      _ = File.rm(prompt_path)
    end
  end

  @impl true
  def stop_session(%{chain: chain}) do
    Cmux.close_lane(chain)
  end

  @doc false
  def generate_turn_id(issue) do
    base =
      case issue do
        %{id: id} when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        _ -> "anon"
      end
      |> String.replace(~r/[^A-Za-z0-9]/, "")

    "#{base}-#{System.system_time(:millisecond)}"
  end

  # Build a single-line bash exec body. Per STEP-3 §3 codex-round-5 finding:
  # do NOT export nonce / SYMPHONY_* vars (the wrapper owns those). Keep the
  # body minimal — wrapper handles sentinel + pgid + wait-for.
  #
  # claude CLI flag verification (PR2, claude 2.x):
  #   - `--input-file` does not exist → use stdin redirect
  #   - `--max-turns` does not exist → claude --print is single-shot,
  #     multi-turn loops live above (PR3 do_run_codex_turns analogue)
  #   - `--turn-timeout` does not exist → controlled by sazo-slave --timeout
  @doc false
  def build_claude_print_cmd(session, prompt, opts) do
    prompt_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-prompt-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.md"
      )

    File.write!(prompt_path, prompt)
    File.chmod!(prompt_path, 0o600)

    resume_arg =
      case session.session_id do
        nil -> []
        "" -> []
        sid when is_binary(sid) -> ["--resume", shell_quote(sid)]
      end

    extra_args =
      opts
      |> Keyword.get(:claude_extra_args, [])
      |> Enum.map(&shell_quote/1)

    args =
      [
        "claude",
        "--print",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--dangerously-skip-permissions"
      ] ++ resume_arg ++ extra_args

    body = """
    #!/usr/bin/env bash
    exec #{Enum.join(args, " ")} < #{shell_quote(prompt_path)}
    """

    {body, prompt_path}
  end

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
