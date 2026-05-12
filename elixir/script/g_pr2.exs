# G-PR2 verification: Claude.CmuxPrintBackend dry-run
#
# Run with:
#   cd elixir
#   PATH="$HOME/.sazo/slaves/bin:$PATH" \
#     mix run script/g_pr2.exs
#
# Pass criteria:
#   - exit 0 from start_session/run_turn/stop_session
#   - summary.session_id is a non-empty binary
#   - sazo-linear log shows zero mutate calls (verified externally)

alias SymphonyElixir.Claude.CmuxPrintBackend
alias SymphonyElixir.Linear.Issue

workspace = File.cwd!()

issue = %Issue{
  id: "g-pr2-fixture",
  identifier: "TEST-G-PR2",
  title: "G-PR2 dry run",
  description: "Stale In Review fixture",
  state: "In Review",
  priority: 3
}

prompt = """
You are running a dry-run from Symphony's PR2 verification harness.
Reply with a single line containing exactly: PR2_DRY_RUN_OK
Do not invoke any tools. Do not modify any files. Do not call Linear.
"""

IO.puts("[g-pr2] start_session workspace=#{workspace}")

{:ok, sess} =
  CmuxPrintBackend.start_session(workspace, chain_name: "g-pr2")

IO.inspect(sess, label: "[g-pr2] session", limit: :infinity)

turn_id = "g-pr2-#{System.system_time(:second)}"

IO.puts("[g-pr2] run_turn turn_id=#{turn_id} (timeout=180s)")

result =
  CmuxPrintBackend.run_turn(sess, prompt, issue,
    turn_id: turn_id,
    attempt_id: 1,
    turn_timeout: 180
  )

case result do
  {:ok, summary, new_sess} ->
    IO.inspect(summary, label: "[g-pr2] summary", limit: :infinity)
    IO.puts("[g-pr2] new_session_id=#{inspect(new_sess.session_id)}")

    cond do
      not is_binary(summary.session_id) or summary.session_id == "" ->
        IO.puts("[g-pr2] FAIL — empty session_id")
        :ok = CmuxPrintBackend.stop_session(new_sess)
        System.halt(1)

      not summary.success ->
        IO.puts("[g-pr2] FAIL — success=false stop_reason=#{inspect(summary.stop_reason)}")
        :ok = CmuxPrintBackend.stop_session(new_sess)
        System.halt(1)

      true ->
        IO.puts("[g-pr2] PASS — session_id=#{summary.session_id} tokens_in=#{summary.tokens_in} tokens_out=#{summary.tokens_out}")
        :ok = CmuxPrintBackend.stop_session(new_sess)
        System.halt(0)
    end

  {:error, reason} ->
    IO.puts("[g-pr2] FAIL — run_turn error=#{inspect(reason)}")
    :ok = CmuxPrintBackend.stop_session(sess)
    System.halt(1)
end
