defmodule SymphonyElixir.Verification.Generic do
  @moduledoc false

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Verification.TodoCode

  @doc """
  Minimal verifier for non-code chains. It requires the workspace to be clean,
  a workpad-like Linear comment to exist, and the issue to have left the active
  polling state.
  """
  @spec verify(String.t(), map(), Path.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def verify(chain, issue, workspace, summary, opts) do
    state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    comment_fetcher = Keyword.get(opts, :issue_comment_fetcher, &Tracker.fetch_issue_comments/1)
    git_runner = Keyword.get(opts, :git_runner, &TodoCode.run_git/2)
    issue_id = TodoCode.issue_id(issue)

    checks = [
      TodoCode.clean_workspace_check(workspace, git_runner),
      TodoCode.linear_target_state_check(issue_id, target_states(chain), state_fetcher),
      TodoCode.workpad_comment_check(issue_id, comment_fetcher)
    ]

    TodoCode.to_result(chain, issue, summary, checks)
  end

  defp target_states("code-review-codex"), do: ["In Review", "Changes Requested"]
  defp target_states("in-review-qa"), do: ["Awaiting Prod Approval", "Changes Requested"]
  defp target_states(_chain), do: ["Code Review"]
end
