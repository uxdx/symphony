defmodule SymphonyElixir.Claude.CmuxPrintBackend do
  @moduledoc """
  PR3 backend. Wires `claude --print --output-format stream-json` through
  `SymphonyElixir.Cmux` (sazo-slave run-turn) so credentials read from the
  macOS keychain succeed (login-keychain unlocked inside the cmux pane shell).

  PR3 contract:

    * `begin_turn` / `complete_turn` / `fail_turn` go through
      `SymphonyElixir.State.Issues` (CAS state machine, fence_seq, per-issue
      flock). Caller must supply an issue with a non-nil identifier.
    * `classify_error/1` maps run_turn errors → 4 reason atoms
      (`:auth_revoked`, `:rate_limit`, `:turn_timeout`, `:sentinel_missing`,
      `:nonce_mismatch`, `:unknown`). `auth_revoked` uses a shorter retry
      schedule (3-step) inside `RetryBudget`. PR4 promotes it to realm pause.
    * No Linear writes from this module yet (PR5 introduces
      `sazo-linear-mutate`). G-PR3 still verifies Linear-mutate-counter == 0.
    * `:state_required` opt (default `true`) — set to `false` for harness runs
      that only want the dry-run / parse path (G-PR2 fixture, no SQLite).
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Cmux
  alias SymphonyElixir.Agent.StreamJsonParser
  alias SymphonyElixir.State.Issues
  alias SymphonyElixir.State.AuthRealms

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
      {:ok, %{turn_id: turn_id, attempt_id: attempt_id, fence_seq: fence_seq}} ->
        {cmd_body, prompt_path} = build_claude_print_cmd(session, prompt, opts)

        try do
          do_run_turn(session, issue_key, turn_id, attempt_id, fence_seq, cmd_body,
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
        Logger.error("[claude_cmux] begin_turn failed: #{inspect(reason)} chain=#{chain}")
        {:error, {:begin_turn_failed, reason}}
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

  @doc """
  Map a run_turn error tuple to a stable reason atom for `RetryBudget`.

  Authoritative classification per STEP-3 §7:

    * `:turn_timeout` — sazo-slave exit 124 (wall-clock cap hit)
    * `:sentinel_missing` — exit 125 (wrapper sentinel not seen)
    * `:nonce_mismatch` — exit 126 (forgery suspect, lane quarantine)
    * `:auth_revoked` — stdout contains "Not logged in" / "401" / "auth_required"
                        / "credentials"
    * `:rate_limit` — stdout contains "rate limit" / "429" / "quota"
    * `:unknown` — anything else
  """
  @spec classify_error(term()) :: :turn_timeout | :sentinel_missing | :nonce_mismatch
                                     | :auth_revoked | :rate_limit | :unknown
  def classify_error(:turn_timeout), do: :turn_timeout
  def classify_error(:sentinel_missing), do: :sentinel_missing
  def classify_error({:nonce_mismatch, _out}), do: :nonce_mismatch
  def classify_error({:turn_failed, _code, out}) when is_binary(out), do: classify_stdout(out)
  def classify_error({:lane_spawn_failed, _}), do: :unknown
  def classify_error({:begin_turn_failed, _}), do: :unknown
  def classify_error(_), do: :unknown

  defp classify_stdout(out) do
    cond do
      String.contains?(out, "Not logged in") or
          String.contains?(out, "auth_required") or
          String.contains?(out, "401") or
          String.contains?(out, "credentials") ->
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

  # For auth_revoked and rate_limit, record the realm-level event and still call
  # fail_turn so the issue exits turn_running. Retry budget is consumed, but the
  # admission gate (begin/3) prevents new turns while the realm is blocked —
  # meaning budget is only burned once per realm-unblock cycle.
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

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  ## Internals

  defp issue_key(%{identifier: id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{id: id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{"identifier" => id}) when is_binary(id) and id != "", do: id
  defp issue_key(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp issue_key(_), do: nil

  defp begin(false, _issue_key, _chain) do
    # state_required? = false → caller (e.g. G-PR2 dry-run harness) opts out of
    # SQLite. Fabricate a turn_id so the rest of the pipeline runs unchanged.
    turn_id = "dryrun-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"
    {:ok, %{turn_id: turn_id, attempt_id: 1, fence_seq: 0}}
  end

  defp begin(true, nil, _chain), do: {:error, :missing_issue_id}

  defp begin(true, issue_key, chain) do
    case AuthRealms.check(AuthRealms.default_realm()) do
      :ok ->
        Issues.begin_turn(issue_key, chain, agent: "claude")

      {:blocked, blocked_until} ->
        Logger.info("[claude_cmux] begin_turn skipped: realm blocked until #{blocked_until} chain=#{chain}")
        {:error, :auth_blocked}

      {:throttled, throttled_until} ->
        Logger.info("[claude_cmux] begin_turn skipped: realm throttled until #{throttled_until} chain=#{chain}")
        {:error, :rate_limited}
    end
  end

  defp do_run_turn(session, issue_key, turn_id, attempt_id, _fence_seq, cmd_body, ctx) do
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
        events = StreamJsonParser.parse(raw_stdout)
        Enum.each(events, on_message)

        summary = StreamJsonParser.summarize(events)
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
        end

        new_session = %{session | session_id: new_sid}
        {:ok, Map.put(summary, :session_id, new_sid), new_session}

      {:error, reason} ->
        classified = classify_error(reason)

        Logger.warning(
          "[claude_cmux] run_turn error reason=#{inspect(reason)} classified=#{classified} chain=#{chain}"
        )

        if state_required? and not is_nil(issue_key) do
          handle_turn_failure(issue_key, turn_id, attempt_id, chain, classified)
        end

        {:error, classified}
    end
  end
end
