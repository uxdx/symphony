defmodule SymphonyElixir.VerificationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.CmuxExecBackend
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.State.AuthRealms
  alias SymphonyElixir.State.Issues
  alias SymphonyElixir.Verification

  defmodule FakeCmux do
    def ensure_lane(chain, workspace, opts) do
      send(self(), {:ensure_lane, chain, workspace, opts})
      {:ok, %{chain: chain, workspace: workspace}}
    end

    def run_turn(chain, opts) do
      send(self(), {:run_turn, chain, opts})
      {:ok, Process.get({__MODULE__, :stdout})}
    end

    def close_lane(chain) do
      send(self(), {:close_lane, chain})
      :ok
    end
  end

  setup do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    AuthRealms.unblock(AuthRealms.default_realm())

    on_exit(fn ->
      case previous_linear_api_key do
        nil -> System.delete_env("LINEAR_API_KEY")
        value -> System.put_env("LINEAR_API_KEY", value)
      end
    end)

    :ok
  end

  test "verifier passes when the protocol summary reports success" do
    issue_id = "TEST-VERIFY-PASS"
    workspace = temp_workspace!("protocol-pass")

    assert {:ok, result} =
             Verification.verify_turn(
               "todo-code",
               %Issue{id: issue_id, identifier: issue_id, state: "In Progress"},
               workspace,
               %{success: true, stop_reason: "completed"},
               verifier_opts(issue_id, workspace)
             )

    assert result.status == :passed
    assert Enum.any?(result.checks, &(&1.name == "turn_protocol_success" and &1.status == :passed))
  end

  test "todo-code codex backend completes only after verifier pass" do
    issue_id = unique_issue_id("todo-pass")
    workspace = temp_workspace!("todo-pass")

    Process.put(
      {FakeCmux, :stdout},
      jsonl([
        %{"type" => "thread.started", "thread_id" => "sess-pass"},
        %{"type" => "turn.completed", "usage" => %{"input_tokens" => 7, "output_tokens" => 11}}
      ])
    )

    assert {:ok, session} =
             CmuxExecBackend.start_session(workspace,
               chain_name: "todo-code",
               cmux_module: FakeCmux
             )

    assert {:ok, summary, new_session} =
             CmuxExecBackend.run_turn(
               session,
               "Do the work",
               %Issue{id: issue_id, identifier: issue_id, state: "In Progress"},
               verifier_opts(issue_id, workspace)
             )

    assert summary.success
    assert summary.session_id == "sess-pass"
    assert new_session.session_id == "sess-pass"

    assert_receive {:run_turn, "todo-code", opts}
    assert opts[:cmd_body] =~ "--json"

    assert {:ok, row} = Issues.get(issue_id)
    assert row.state == "completed"
  end

  test "todo-code codex backend fails the turn when verifier rejects the summary" do
    issue_id = unique_issue_id("todo-fail")
    workspace = temp_workspace!("todo-fail")

    Process.put(
      {FakeCmux, :stdout},
      jsonl([
        %{"type" => "thread.started", "thread_id" => "sess-fail"},
        %{"type" => "turn.failed", "error" => "model reported failure"}
      ])
    )

    assert {:ok, session} =
             CmuxExecBackend.start_session(workspace,
               chain_name: "todo-code",
               cmux_module: FakeCmux
             )

    assert {:error, {:verification_failed, verification}} =
             CmuxExecBackend.run_turn(
               session,
               "Do the work",
               %Issue{id: issue_id, identifier: issue_id, state: "In Progress"},
               verifier_opts(issue_id, workspace)
             )

    assert verification.status == :failed
    assert verification.classification == :retryable
    assert verification.reason == "turn_protocol_success"

    assert {:ok, row} = Issues.get(issue_id)
    assert row.state == "retryable_failed"
    assert row.last_failure_reason == "verification_retryable"
  end

  defp unique_issue_id(label) do
    "TEST-VERIFY-#{label}-#{System.unique_integer([:positive])}"
  end

  defp temp_workspace!(label) do
    path = Path.join(System.tmp_dir!(), "symphony-verification-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp verifier_opts(issue_id, workspace) do
    [
      expected_branch: "feature/test",
      issue_state_fetcher: fn [^issue_id] ->
        {:ok, [%Issue{id: issue_id, identifier: issue_id, state: "Code Review"}]}
      end,
      issue_comment_fetcher: fn ^issue_id ->
        {:ok, [%{"body" => "## Codex Workpad\n\n### Validation\n- [x] unit"}]}
      end,
      git_runner: fn ^workspace, args -> fake_git(issue_id, args) end
    ]
  end

  defp fake_git(_issue_id, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {:ok, "feature/test\n"}
  defp fake_git(_issue_id, ["status", "--porcelain"]), do: {:ok, ""}
  defp fake_git(_issue_id, ["rev-parse", "HEAD"]), do: {:ok, "abc123\n"}
  defp fake_git(_issue_id, ["rev-parse", "origin/feature/test"]), do: {:ok, "abc123\n"}
  defp fake_git(issue_id, ["log", "-50", "--format=%H%x09%s", "--grep=" <> issue_id]), do: {:ok, "abc123\t#{issue_id}\n"}
  defp fake_git(_issue_id, args), do: {:error, %{exit_code: 1, output: Enum.join(args, " ")}}

  defp jsonl(events) do
    Enum.map_join(events, "\n", &Jason.encode!/1)
  end
end
