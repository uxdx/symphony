defmodule SymphonyElixir.Codex.CmuxExecBackend do
  @moduledoc """
  PR7b backend. Wires `codex exec --json` through `SymphonyElixir.Cmux`
  (sazo-slave run-turn) so auth reads from the local codex keychain succeed.

  PR7b contract:

    * `begin_turn` / `complete_turn` / `fail_turn` go through
      `SymphonyElixir.State.Issues` (same CAS state machine as CmuxPrintBackend).
    * First turn: `codex exec --json -C <workspace> --dangerously-bypass-approvals-and-sandbox`
    * Subsequent turns (session_id set): `codex exec resume <session_id> --json --dangerously-...`
    * Auth/rate-limit errors → AuthRealms.block/throttle + Issues.fail_turn (same as PR4).
    * LinearMutate.post_turn_comment on every successful complete_turn (same as PR5).
    * `linear_graphql` DynamicTool replaced by the `linear@openai-curated` codex plugin
      (already enabled on macmini via `~/.codex/config.toml`).
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Cmux
  alias SymphonyElixir.Codex.ExecJsonParser
  alias SymphonyElixir.Linear.Mutate
  alias SymphonyElixir.State.{AuthRealms, Issues}

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
    state_required? = Keyword.get(opts, :state_required, true)
    timeout = Keyword.get(opts, :turn_timeout, 3600)
    issue_key = issue_key(issue)

    case begin(state_required?, issue_key, chain) do
      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} ->
        {cmd_body, prompt_path} = build_codex_exec_cmd(session, prompt)

        try do
          do_run_turn(session, issue_key, turn_id, attempt_id, cmd_body,
            chain: chain,
            workspace: workspace,
            timeout: timeout,
            opts: opts,
            state_required?: state_required?
          )
        after
          _ = File.rm(prompt_path)
        end

      {:error, :auth_blocked} = err ->
        err

      {:error, :rate_limited} = err ->
        err

      {:error, reason} ->
        Logger.error("[codex_cmux] begin_turn failed: #{inspect(reason)} chain=#{chain}")
        {:error, {:begin_turn_failed, reason}}
    end
  end

  @impl true
  def stop_session(%{chain: chain}) do
    Cmux.close_lane(chain)
  end

  @doc false
  def build_codex_exec_cmd(session, prompt) do
    prompt_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.md"
      )

    File.write!(prompt_path, prompt)
    File.chmod!(prompt_path, 0o600)

    args =
      case session.session_id do
        sid when is_binary(sid) and sid != "" ->
          [
            "codex", "exec", "resume", shell_quote(sid),
            "--json",
            "--dangerously-bypass-approvals-and-sandbox"
          ]

        _ ->
          [
            "codex", "exec",
            "--json",
            "-C", shell_quote(session.workspace),
            "--dangerously-bypass-approvals-and-sandbox"
          ]
      end

    body = """
    #!/usr/bin/env bash
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    exec #{Enum.join(args, " ")} < #{shell_quote(prompt_path)}
    """

    {body, prompt_path}
  end

  ## Internals

  defp begin(false, _issue_key, _chain) do
    turn_id = "dryrun-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"
    {:ok, %{turn_id: turn_id, attempt_id: 1, fence_seq: 0}}
  end

  defp begin(true, nil, _chain), do: {:error, :missing_issue_id}

  defp begin(true, issue_key, chain) do
    case AuthRealms.check(AuthRealms.default_realm()) do
      :ok ->
        Issues.begin_turn(issue_key, chain, agent: "codex")

      {:blocked, blocked_until} ->
        Logger.info("[codex_cmux] begin_turn skipped: realm blocked until #{blocked_until} chain=#{chain}")
        {:error, :auth_blocked}

      {:throttled, throttled_until} ->
        Logger.info("[codex_cmux] begin_turn skipped: realm throttled until #{throttled_until} chain=#{chain}")
        {:error, :rate_limited}
    end
  end

  defp do_run_turn(session, issue_key, turn_id, attempt_id, cmd_body, ctx) do
    chain = Keyword.fetch!(ctx, :chain)
    workspace = Keyword.fetch!(ctx, :workspace)
    timeout = Keyword.fetch!(ctx, :timeout)
    opts = Keyword.fetch!(ctx, :opts)
    state_required? = Keyword.fetch!(ctx, :state_required?)

    case Cmux.run_turn(chain,
           workspace: workspace,
           turn_id: turn_id,
           attempt_id: attempt_id,
           cmd_body: cmd_body,
           timeout: timeout
         ) do
      {:ok, raw_stdout} ->
        on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
        events = ExecJsonParser.parse(raw_stdout)
        Enum.each(events, fn ev -> on_message.(%{event: :codex_exec_event, data: ev}) end)

        summary = ExecJsonParser.summarize(events)
        new_sid = summary[:session_id] || session.session_id

        if state_required? and not is_nil(issue_key) do
          :ok =
            Issues.complete_turn(issue_key, %{
              attempt_id: attempt_id,
              turn_id: turn_id,
              chain: chain,
              session_id: new_sid,
              summary: summary
            })

          :ok = Mutate.post_turn_comment(issue_key, chain, Map.put(summary, :session_id, new_sid))
        end

        new_session = %{session | session_id: new_sid}
        {:ok, Map.put(summary, :session_id, new_sid), new_session}

      {:error, reason} ->
        classified = classify_error(reason)

        Logger.warning(
          "[codex_cmux] run_turn error reason=#{inspect(reason)} classified=#{classified} chain=#{chain}"
        )

        if state_required? and not is_nil(issue_key) do
          handle_turn_failure(issue_key, turn_id, attempt_id, chain, classified)
        end

        {:error, classified}
    end
  end

  defp classify_error(:turn_timeout), do: :turn_timeout
  defp classify_error(:sentinel_missing), do: :sentinel_missing
  defp classify_error({:nonce_mismatch, _out}), do: :nonce_mismatch
  defp classify_error({:turn_failed, _code, out}) when is_binary(out), do: classify_stdout(out)
  defp classify_error(_), do: :unknown

  defp classify_stdout(out) do
    cond do
      String.contains?(out, "TokenRefreshFailed") or
          String.contains?(out, "invalid_grant") or
          String.contains?(out, "auth_required") or
          String.contains?(out, "Not logged in") ->
        :auth_revoked

      String.contains?(out, "rate limit") or
          String.contains?(out, "429") or
          String.contains?(out, "quota") ->
        :rate_limit

      String.contains?(out, "timeout") or
          String.contains?(out, "deadline") ->
        :turn_timeout

      true ->
        :unknown
    end
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, :auth_revoked) do
    :ok = AuthRealms.block(AuthRealms.default_realm())

    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: :auth_revoked
      })
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, :rate_limit) do
    retry_at = System.system_time(:second) + 3600
    :ok = AuthRealms.throttle(AuthRealms.default_realm(), retry_at)

    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: :rate_limit
      })
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, reason) do
    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: reason
      })
  end

  defp issue_key(%{identifier: id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{id: id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{"identifier" => id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp issue_key(_), do: nil

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
