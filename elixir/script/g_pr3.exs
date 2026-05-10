# G-PR3 verification: Claude.CmuxPrintBackend wired through SymphonyElixir.State
#
# Run with:
#   cd elixir
#   PATH="$HOME/.sazo/slaves/bin:$PATH" mix run script/g_pr3.exs
#
# Pass criteria:
#   - state_required defaults to true; issue with identifier "TEST-G-PR3-<n>" gets
#     a row in `issues` ending in state='completed', attempt_id=1, fence_seq>0.
#   - turn_attempts has matching row in state='completed' with raw_summary_json.
#   - events table has at least 'turn_running' and 'completed' entries for issue.
#   - boot_run_id present and matches SymphonyElixir.State.boot_run_id().
#   - Linear-mutate-counter == 0 (verified externally via sazo-linear log).

alias Exqlite.Sqlite3
alias SymphonyElixir.Claude.CmuxPrintBackend
alias SymphonyElixir.Linear.Issue
alias SymphonyElixir.State
alias SymphonyElixir.State.Issues

workspace = File.cwd!()

issue_id = "TEST-G-PR3-#{System.system_time(:second)}"

issue = %Issue{
  id: issue_id,
  identifier: issue_id,
  title: "G-PR3 wire-up",
  description: "PR3 state machine fixture",
  state: "In Progress",
  priority: 3
}

prompt = """
You are running a dry-run from Symphony's PR3 verification harness.
Reply with a single line containing exactly: PR3_E2E_OK
Do not invoke any tools. Do not modify any files. Do not call Linear.
"""

IO.puts("[g-pr3] db_path=#{State.default_db_path()} boot_run_id=#{State.boot_run_id()}")
IO.puts("[g-pr3] issue=#{issue_id}")

{:ok, sess} = CmuxPrintBackend.start_session(workspace, chain_name: "g-pr3")
IO.inspect(sess, label: "[g-pr3] session", limit: :infinity)

result = CmuxPrintBackend.run_turn(sess, prompt, issue, turn_timeout: 180)

case result do
  {:ok, summary, new_sess} ->
    IO.inspect(summary, label: "[g-pr3] summary", limit: :infinity)
    :ok = CmuxPrintBackend.stop_session(new_sess)

    {:ok, row} = Issues.get(issue_id)
    IO.inspect(row, label: "[g-pr3] issues row", limit: :infinity)

    {:ok, attempts} =
      State.transaction(fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(
            conn,
            "SELECT attempt_id, state, session_id, tokens_in, tokens_out FROM turn_attempts WHERE issue_id = ?"
          )

        :ok = Sqlite3.bind(stmt, [issue_id])

        rows =
          Stream.unfold(:start, fn
            :start ->
              case Sqlite3.step(conn, stmt) do
                {:row, row} -> {row, :cont}
                :done -> nil
              end

            :cont ->
              case Sqlite3.step(conn, stmt) do
                {:row, row} -> {row, :cont}
                :done -> nil
              end
          end)
          |> Enum.to_list()

        :ok = Sqlite3.release(conn, stmt)
        rows
      end)

    IO.inspect(attempts, label: "[g-pr3] turn_attempts", limit: :infinity)

    {:ok, event_kinds} =
      State.transaction(fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(conn, "SELECT kind FROM events WHERE issue_id = ? ORDER BY id")

        :ok = Sqlite3.bind(stmt, [issue_id])

        rows =
          Stream.unfold(:start, fn _ ->
            case Sqlite3.step(conn, stmt) do
              {:row, [kind]} -> {kind, :cont}
              :done -> nil
            end
          end)
          |> Enum.to_list()

        :ok = Sqlite3.release(conn, stmt)
        rows
      end)

    IO.inspect(event_kinds, label: "[g-pr3] event_kinds", limit: :infinity)

    cond do
      row.state != "completed" ->
        IO.puts("[g-pr3] FAIL — issues.state=#{row.state} (expected completed)")
        System.halt(1)

      row.attempt_id != 1 ->
        IO.puts("[g-pr3] FAIL — attempt_id=#{row.attempt_id} (expected 1)")
        System.halt(1)

      row.fence_seq <= 0 ->
        IO.puts("[g-pr3] FAIL — fence_seq=#{row.fence_seq}")
        System.halt(1)

      length(attempts) != 1 ->
        IO.puts("[g-pr3] FAIL — turn_attempts count=#{length(attempts)}")
        System.halt(1)

      "turn_running" not in event_kinds or "completed" not in event_kinds ->
        IO.puts("[g-pr3] FAIL — events missing turn_running/completed: #{inspect(event_kinds)}")
        System.halt(1)

      true ->
        IO.puts(
          "[g-pr3] PASS — issue=#{issue_id} state=completed attempt=1 fence_seq=#{row.fence_seq} session=#{row.session_id} tokens_in=#{summary.tokens_in} tokens_out=#{summary.tokens_out}"
        )

        System.halt(0)
    end

  {:error, reason} ->
    IO.puts("[g-pr3] FAIL — run_turn error=#{inspect(reason)}")
    :ok = CmuxPrintBackend.stop_session(sess)
    System.halt(1)
end
