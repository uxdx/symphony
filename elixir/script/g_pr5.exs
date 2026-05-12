# G-PR5 verification: LinearMutate posts a turn-completion comment to Linear
#
# Run with:
#   cd elixir
#   LINEAR_API_KEY=<key> PATH="$HOME/.sazo/slaves/bin:$HOME/.sazo/bin:$PATH" \
#     mix run script/g_pr5.exs
#
# Pass criteria:
#   - run_turn returns {:ok, summary, session} (same as G-PR3)
#   - Linear-mutate-counter > 0 in ~/.sazo/logs/linear-mutate.log after run
#   - The log line contains issue_id and exit=0
#
# If LINEAR_API_KEY is not set, the script emits a warning and verifies that
# the log is NOT written (correct graceful-skip behavior).

alias SymphonyElixir.Claude.CmuxPrintBackend
alias SymphonyElixir.Linear.Issue
alias SymphonyElixir.State

log_file = Path.join([System.user_home!(), ".sazo", "logs", "linear-mutate.log"])

issue_id = "TEST-G-PR5-#{System.system_time(:second)}"

issue = %Issue{
  id: issue_id,
  identifier: issue_id,
  title: "G-PR5 linear-mutate",
  description: "PR5 Linear write fixture",
  state: "In Progress",
  priority: 3
}

prompt = """
You are running a dry-run from Symphony's PR5 verification harness.
Reply with a single line containing exactly: PR5_LINEAR_OK
Do not invoke any tools. Do not modify any files.
"""

api_key_set? = not is_nil(System.get_env("LINEAR_API_KEY"))

IO.puts("[g-pr5] issue=#{issue_id} linear_api_key=#{if api_key_set?, do: "set", else: "NOT SET"}")

# Capture log line count before run
lines_before =
  if File.exists?(log_file) do
    log_file |> File.read!() |> String.split("\n", trim: true) |> length()
  else
    0
  end

workspace = File.cwd!()
{:ok, sess} = CmuxPrintBackend.start_session(workspace, chain_name: "g-pr5")

result = CmuxPrintBackend.run_turn(sess, prompt, issue, turn_timeout: 180)

case result do
  {:ok, summary, new_sess} ->
    IO.inspect(summary, label: "[g-pr5] summary", limit: :infinity)
    :ok = CmuxPrintBackend.stop_session(new_sess)

    lines_after =
      if File.exists?(log_file) do
        log_file |> File.read!() |> String.split("\n", trim: true) |> length()
      else
        0
      end

    new_lines = lines_after - lines_before

    cond do
      api_key_set? and new_lines > 0 ->
        last_line = log_file |> File.read!() |> String.split("\n", trim: true) |> List.last()
        IO.puts("[g-pr5] PASS — linear-mutate log +#{new_lines} line(s), last: #{last_line}")
        System.halt(0)

      api_key_set? and new_lines == 0 ->
        IO.puts("[g-pr5] FAIL — LINEAR_API_KEY set but linear-mutate.log got no new lines")
        System.halt(1)

      not api_key_set? and new_lines == 0 ->
        IO.puts("[g-pr5] PASS (no-key mode) — Linear write correctly skipped when LINEAR_API_KEY unset")
        System.halt(0)

      not api_key_set? and new_lines > 0 ->
        IO.puts("[g-pr5] FAIL — linear-mutate.log written despite missing LINEAR_API_KEY")
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts("[g-pr5] FAIL — run_turn error=#{inspect(reason)}")
    :ok = CmuxPrintBackend.stop_session(sess)
    System.halt(1)
end
