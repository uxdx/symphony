defmodule SymphonyElixir.Verification.TodoCodeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Verification

  test "todo-code fixture passes only with git, Linear, and workpad evidence" do
    workspace = git_fixture!("AGT1-466")

    issue = %Issue{
      id: "issue-uuid-1",
      identifier: "AGT1-466",
      title: "Verifier fixture",
      state: "In Progress"
    }

    state_fetcher = fn ["issue-uuid-1"] ->
      {:ok, [%Issue{id: "issue-uuid-1", identifier: "AGT1-466", state: "Code Review"}]}
    end

    comment_fetcher = fn "issue-uuid-1" ->
      {:ok, [%{"body" => "## Codex Workpad\n\n### Validation\n- [x] unit"}]}
    end

    assert {:ok, result} =
             Verification.verify_turn("todo-code", issue, workspace, %{success: true},
               issue_state_fetcher: state_fetcher,
               issue_comment_fetcher: comment_fetcher
             )

    assert result.status == :passed
    assert Enum.all?(result.checks, &(&1.status == :passed))
  end

  test "todo-code fixture fails as retryable when external Linear state is still active" do
    workspace = git_fixture!("AGT1-467")

    issue = %Issue{id: "issue-uuid-2", identifier: "AGT1-467", state: "In Progress"}

    state_fetcher = fn ["issue-uuid-2"] ->
      {:ok, [%Issue{id: "issue-uuid-2", identifier: "AGT1-467", state: "In Progress"}]}
    end

    comment_fetcher = fn "issue-uuid-2" ->
      {:ok, [%{"body" => "## Codex Workpad\n\n### Validation\n- [x] unit"}]}
    end

    assert {:error, result} =
             Verification.verify_turn("todo-code", issue, workspace, %{success: true},
               issue_state_fetcher: state_fetcher,
               issue_comment_fetcher: comment_fetcher
             )

    assert result.status == :failed
    assert result.classification == :retryable
    assert Enum.any?(result.checks, &(&1.name == "linear.target_state" and &1.status == :failed))
  end

  defp git_fixture!(identifier) do
    workspace = Path.join(System.tmp_dir!(), "symphony-verifier-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(workspace, "README.md"), "#{identifier}\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "feat: fixture evidence (#{identifier})"])
    git!(workspace, ["branch", "-M", "feature/cs-tool-launch"])

    {head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    git!(workspace, ["update-ref", "refs/remotes/origin/feature/cs-tool-launch", String.trim(head)])

    workspace
  end

  defp git!(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{out}")
    end
  end
end
