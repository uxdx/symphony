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
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Mutate
  alias SymphonyElixir.State.{AuthRealms, Issues}
  alias SymphonyElixir.Verification

  require Logger

  @impl true
  def start_session(workspace, opts) do
    chain = Keyword.fetch!(opts, :chain_name)
    cmux_module = Keyword.get(opts, :cmux_module, Cmux)

    case cmux_module.ensure_lane(chain, workspace, agent: "shell") do
      {:ok, lane} ->
        session = %{
          chain: chain,
          cmux_module: cmux_module,
          exec_command: Keyword.get(opts, :exec_command) || configured_exec_command(),
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
          do_run_turn(session, issue, issue_key, turn_id, attempt_id, cmd_body,
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
  def stop_session(%{chain: chain} = session) do
    cmux_module = Map.get(session, :cmux_module, Cmux)
    cmux_module.close_lane(chain)
  end

  @doc false
  @spec build_codex_exec_cmd(map(), String.t()) :: {String.t(), Path.t()}
  def build_codex_exec_cmd(session, prompt) do
    prompt_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.md"
      )

    File.write!(prompt_path, sanitize_utf8(prompt))
    File.chmod!(prompt_path, 0o600)

    cmd =
      case session.session_id do
        sid when is_binary(sid) and sid != "" ->
          "#{exec_command(session)} resume #{shell_quote(sid)} --json --dangerously-bypass-approvals-and-sandbox"

        _ ->
          "#{exec_command(session)} -C #{shell_quote(session.workspace)} --json --dangerously-bypass-approvals-and-sandbox"
      end

    body = """
    #!/usr/bin/env bash
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    exec #{cmd} < #{shell_quote(prompt_path)}
    """

    {body, prompt_path}
  end

  defp configured_exec_command do
    case Config.settings() do
      {:ok, settings} ->
        settings.codex.exec_command

      {:error, _reason} ->
        "codex exec"
    end
  end

  defp exec_command(%{exec_command: command}) when is_binary(command) do
    case String.trim(command) do
      "" -> "codex exec"
      value -> value
    end
  end

  defp exec_command(_session), do: "codex exec"

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

  defp do_run_turn(session, issue, issue_key, turn_id, attempt_id, cmd_body, ctx) do
    chain = Keyword.fetch!(ctx, :chain)
    workspace = Keyword.fetch!(ctx, :workspace)
    timeout = Keyword.fetch!(ctx, :timeout)
    opts = Keyword.fetch!(ctx, :opts)
    state_required? = Keyword.fetch!(ctx, :state_required?)

    cmux_module = Map.get(session, :cmux_module, Cmux)

    case cmux_module.run_turn(chain,
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

        completion =
          if state_required? and not is_nil(issue_key) do
            complete_after_verification(issue_key, issue, workspace, turn_id, attempt_id, chain, new_sid, summary, opts)
          else
            :ok
          end

        case completion do
          :ok ->
            new_session = %{session | session_id: new_sid}
            {:ok, Map.put(summary, :session_id, new_sid), new_session}

          {:error, result} ->
            {:error, {:verification_failed, result}}
        end

      {:error, reason} ->
        classified = classify_error(reason)

        Logger.warning("[codex_cmux] run_turn error reason=#{inspect(reason)} classified=#{classified} chain=#{chain}")

        :ok = maybe_handle_turn_failure(state_required?, issue_key, turn_id, attempt_id, chain, classified)

        {:error, classified}
    end
  end

  defp maybe_handle_turn_failure(true, issue_key, turn_id, attempt_id, chain, reason)
       when not is_nil(issue_key) do
    handle_turn_failure(issue_key, turn_id, attempt_id, chain, reason)
  end

  defp maybe_handle_turn_failure(_state_required?, _issue_key, _turn_id, _attempt_id, _chain, _reason),
    do: :ok

  defp classify_error(:turn_timeout), do: :turn_timeout
  defp classify_error(:sentinel_missing), do: :sentinel_missing
  defp classify_error({:nonce_mismatch, _out}), do: :nonce_mismatch
  defp classify_error({:turn_failed, _code, out}) when is_binary(out), do: classify_stdout(out)
  defp classify_error(_), do: :unknown

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp complete_after_verification(issue_key, issue, workspace, turn_id, attempt_id, chain, new_sid, summary, opts) do
    :ok =
      Issues.begin_verification(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        session_id: new_sid,
        summary: summary
      })

    case Verification.verify_turn(chain, issue, workspace, summary, opts) do
      {:ok, result} ->
        :ok = record_verification_result(issue_key, turn_id, attempt_id, chain, result)

        :ok =
          Issues.complete_turn(issue_key, %{
            attempt_id: attempt_id,
            turn_id: turn_id,
            chain: chain,
            session_id: new_sid,
            summary: summary,
            verification: result,
            expected_state: "verifying"
          })

        :ok = Mutate.post_turn_comment(issue_key, chain, Map.put(summary, :session_id, new_sid))
        :ok

      {:error, result} ->
        :ok = record_verification_result(issue_key, turn_id, attempt_id, chain, result)

        {:ok, _} =
          Issues.fail_turn(issue_key, %{
            attempt_id: attempt_id,
            turn_id: turn_id,
            chain: chain,
            reason: Verification.retry_reason(result),
            classification: Map.get(result, :classification),
            verification: result,
            expected_state: "verifying"
          })

        {:error, result}
    end
  end

  defp record_verification_result(issue_key, turn_id, attempt_id, chain, result) do
    Issues.record_verification_result(issue_key, %{
      attempt_id: attempt_id,
      turn_id: turn_id,
      chain: chain,
      result: result
    })
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp classify_stdout(out) do
    # Scan only the last 50 lines to avoid false positives from prompt content
    # or bash terminal echoes that may contain user issue text.
    tail =
      out
      |> String.split("\n")
      |> Enum.take(-50)
      |> Enum.join("\n")
      |> String.downcase()

    cond do
      String.contains?(tail, "tokenrefreshfailed") or
        String.contains?(tail, "invalid_grant") or
        String.contains?(tail, "auth_required") or
        String.contains?(tail, "not logged in") or
          String.contains?(tail, "credentials") ->
        :auth_revoked

      String.contains?(tail, "rate limit exceeded") or
        String.contains?(tail, "too many requests") or
        String.contains?(tail, "rate_limit_exceeded") or
        String.contains?(tail, "http 429") or
        String.contains?(tail, "429") or
          String.contains?(tail, "quota") ->
        :rate_limit

      String.contains?(tail, "timeout") or
          String.contains?(tail, "deadline") ->
        :turn_timeout

      true ->
        :unknown
    end
  end

  defp sanitize_utf8(str) when is_binary(str) do
    for <<c::utf8 <- str>>, into: "", do: <<c::utf8>>
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, reason, details \\ nil)

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, :auth_revoked, details) do
    :ok = AuthRealms.block(AuthRealms.default_realm())

    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: :auth_revoked,
        details: details
      })

    :ok
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, :rate_limit, details) do
    retry_at = System.system_time(:second) + 3600
    :ok = AuthRealms.throttle(AuthRealms.default_realm(), retry_at)

    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: :rate_limit,
        details: details
      })

    :ok
  end

  defp handle_turn_failure(issue_key, turn_id, attempt_id, chain, reason, details) do
    {:ok, _} =
      Issues.fail_turn(issue_key, %{
        attempt_id: attempt_id,
        turn_id: turn_id,
        chain: chain,
        reason: reason,
        details: details
      })

    :ok
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
