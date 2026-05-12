defmodule SymphonyElixir.VerificationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.CmuxExecBackend
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
    assert {:ok, result} =
             Verification.verify_turn(%{
               issue_id: "TEST-VERIFY-PASS",
               chain: "todo-code",
               summary: %{success: true, stop_reason: "completed"}
             })

    assert result.status == "passed"
    assert result.reason == "verified"
    assert [%{name: "turn_protocol_success", status: "passed"}] = result.checks
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
             CmuxExecBackend.run_turn(session, "Do the work", %{identifier: issue_id}, [])

    assert summary.success
    assert summary.session_id == "sess-pass"
    assert summary.verification.status == "passed"
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
             CmuxExecBackend.run_turn(session, "Do the work", %{identifier: issue_id}, [])

    assert verification.status == "failed"
    assert verification.failure_class == "retryable"
    assert verification.reason == "verification_failed"

    assert {:ok, row} = Issues.get(issue_id)
    assert row.state == "retryable_failed"
    assert row.last_failure_reason == "verification_failed"
  end

  defp unique_issue_id(label) do
    "TEST-VERIFY-#{label}-#{System.unique_integer([:positive])}"
  end

  defp temp_workspace!(label) do
    path = Path.join(System.tmp_dir!(), "symphony-verification-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp jsonl(events) do
    events
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end
end
