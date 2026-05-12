defmodule SymphonyElixir.Linear.Mutate do
  @moduledoc """
  PR5 Linear write façade. Calls `sazo-linear-mutate` (flock-coordinated
  shell wrapper) to post Symphony turn-completion comments back to Linear.

  Gated by `LINEAR_API_KEY` env: if not set, logs a warning and skips
  without failing the turn. This allows PR5 to deploy before the env var
  is wired into every chain plist.

  Called from `CmuxPrintBackend.do_run_turn/7` after `Issues.complete_turn`.
  """

  require Logger

  @sazo_linear_mutate "sazo-linear-mutate"

  @doc """
  Post a Symphony turn-completion comment to the Linear issue.

  `issue_key` — Linear issue identifier (e.g. "AGT1-123") or UUID.
  `chain` — chain name for the comment footer.
  `summary` — StreamJsonParser summary map.
  """
  @spec post_turn_comment(String.t(), String.t(), map()) :: :ok
  def post_turn_comment(issue_key, chain, summary) do
    case System.get_env("LINEAR_API_KEY") do
      nil ->
        Logger.debug("[linear_mutate] LINEAR_API_KEY not set — skipping Linear comment for #{issue_key}")
        :ok

      _ ->
        body = build_comment(chain, summary)
        run_mutate(issue_key, body)
    end
  end

  ## Internals

  defp build_comment(chain, summary) do
    session_id = Map.get(summary, :session_id) || "—"
    tool_calls = Map.get(summary, :tool_calls, 0)
    tokens_in = Map.get(summary, :tokens_in, 0)
    tokens_out = Map.get(summary, :tokens_out, 0)
    stop_reason = Map.get(summary, :stop_reason) || "—"

    """
    <!-- symphony:turn -->
    **Symphony turn completed** (chain=`#{chain}`)

    | field | value |
    |---|---|
    | session | `#{session_id}` |
    | stop reason | #{stop_reason} |
    | tool calls | #{tool_calls} |
    | tokens in/out | #{tokens_in} / #{tokens_out} |
    """
  end

  defp run_mutate(issue_key, body) do
    tmp = Path.join(System.tmp_dir!(), "symphony-linear-comment-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}.md")

    try do
      File.write!(tmp, body)

      sazo_bin = Path.join([System.user_home!(), ".sazo", "bin"])
      env = [{"PATH", "#{sazo_bin}:#{System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin")}"}]

      case System.cmd(@sazo_linear_mutate, ["comment", issue_key, tmp],
             env: env,
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          Logger.info("[linear_mutate] posted turn comment to #{issue_key}")
          :ok

        {out, code} ->
          Logger.warning("[linear_mutate] sazo-linear-mutate exited #{code} for #{issue_key}: #{String.trim(out)}")
          :ok
      end
    rescue
      e ->
        Logger.warning("[linear_mutate] error posting comment to #{issue_key}: #{inspect(e)}")
        :ok
    after
      File.rm(tmp)
    end
  end
end
