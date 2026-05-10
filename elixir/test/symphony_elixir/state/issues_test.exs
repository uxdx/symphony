defmodule SymphonyElixir.State.IssuesTest do
  # Shares the application's singleton State (test DB path from config/test.exs).
  # Each test uses a unique issue_id so rows do not collide.
  use ExUnit.Case, async: false

  alias SymphonyElixir.State
  alias SymphonyElixir.State.Issues

  defp unique_issue_id(label) do
    "TEST-#{label}-#{System.unique_integer([:positive])}"
  end

  describe "begin_turn/3" do
    test "inserts an issues row in turn_running state with attempt_id=1" do
      issue_id = unique_issue_id("begin")

      assert {:ok, %{turn_id: turn_id, attempt_id: 1, fence_seq: fence_seq}} =
               Issues.begin_turn(issue_id, "todo-code-chain")

      assert is_binary(turn_id)
      assert is_integer(fence_seq) and fence_seq > 0

      {:ok, row} = Issues.get(issue_id)
      assert row.state == "turn_running"
      assert row.attempt_id == 1
      assert row.chain == "todo-code-chain"
      assert row.fence_seq == fence_seq
      assert row.current_turn_id == turn_id
      assert row.owner_boot_run_id == State.boot_run_id()
    end

    test "second begin_turn on same issue increments attempt_id" do
      issue_id = unique_issue_id("attempt")

      {:ok, %{attempt_id: 1, fence_seq: f1}} = Issues.begin_turn(issue_id, "c1")
      {:ok, %{attempt_id: 2, fence_seq: f2}} = Issues.begin_turn(issue_id, "c1")

      assert f2 > f1
      {:ok, row} = Issues.get(issue_id)
      assert row.attempt_id == 2
    end

    test "fence_seq is monotonic across distinct issues" do
      issue_a = unique_issue_id("fence-a")
      issue_b = unique_issue_id("fence-b")

      {:ok, %{fence_seq: fa}} = Issues.begin_turn(issue_a, "c1")
      {:ok, %{fence_seq: fb}} = Issues.begin_turn(issue_b, "c1")

      assert fb > fa
    end
  end

  describe "complete_turn/2" do
    test "marks issue completed and clears retry/owner fields" do
      issue_id = unique_issue_id("complete")

      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} =
        Issues.begin_turn(issue_id, "c-complete")

      assert :ok =
               Issues.complete_turn(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "c-complete",
                 session_id: "sess-abc",
                 summary: %{tokens_in: 5, tokens_out: 18, success: true}
               })

      {:ok, row} = Issues.get(issue_id)
      assert row.state == "completed"
      assert row.session_id == "sess-abc"
      assert row.retry_budget_used == 0
      assert is_nil(row.retry_next_at)
      assert is_nil(row.owner_boot_run_id)
      assert is_nil(row.current_turn_id)
    end

    test "rejects with :stale_state when issue is no longer turn_running" do
      issue_id = unique_issue_id("stale")
      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-stale")

      # Move to retryable_failed first
      {:ok, _} =
        Issues.fail_turn(issue_id, %{
          attempt_id: attempt_id,
          turn_id: turn_id,
          chain: "c-stale",
          reason: :turn_timeout
        })

      # Now complete_turn should reject the stale CAS
      assert {:error, {:stale_state, _err}} =
               Issues.complete_turn(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "c-stale",
                 session_id: nil,
                 summary: %{}
               })
    end
  end

  describe "fail_turn/2" do
    test "default reason → retryable_failed within budget, retry_next_at set" do
      issue_id = unique_issue_id("fail-default")

      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c1")

      # Inject deterministic clock & rand for retry_next_at
      assert {:ok, %{state: "retryable_failed", retry_budget_used: 1, retry_next_at: rt}} =
               Issues.fail_turn(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "c1",
                 reason: :turn_timeout,
                 now: fn -> 1_000_000 end,
                 rand: fn -> 0.5 end
               })

      # base=60, jitter=0 → 1_000_060
      assert rt == 1_000_060
    end

    test "auth_revoked beyond cap (3) transitions to quarantined" do
      issue_id = unique_issue_id("fail-auth")

      Enum.each(1..3, fn _ ->
        {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-auth")

        {:ok, _} =
          Issues.fail_turn(issue_id, %{
            attempt_id: attempt_id,
            turn_id: turn_id,
            chain: "c-auth",
            reason: :auth_revoked,
            now: fn -> 0 end,
            rand: fn -> 0.5 end
          })
      end)

      # 4th attempt → cap exhausted (auth_revoked schedule has 3 entries)
      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-auth")

      assert {:ok, %{state: "quarantined", retry_budget_used: 4, retry_next_at: nil}} =
               Issues.fail_turn(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "c-auth",
                 reason: :auth_revoked
               })

      {:ok, row} = Issues.get(issue_id)
      assert row.state == "quarantined"
      assert row.last_failure_reason == "auth_revoked"
    end
  end

  describe "in_flight/0" do
    test "returns issues whose state is not completed/quarantined" do
      issue_id = unique_issue_id("inflight")
      {:ok, _} = Issues.begin_turn(issue_id, "c-inflight")

      ids = Enum.map(Issues.in_flight(), & &1.issue_id)
      assert issue_id in ids
    end
  end
end
