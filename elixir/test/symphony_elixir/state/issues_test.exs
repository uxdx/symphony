defmodule SymphonyElixir.State.IssuesTest do
  # Shares the application's singleton State (test DB path from config/test.exs).
  # Each test uses a unique issue_id so rows do not collide.
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
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
    test "records verifier result before completing from verifying state" do
      issue_id = unique_issue_id("verify-pass")

      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} =
        Issues.begin_turn(issue_id, "todo-code")

      summary = %{tokens_in: 5, tokens_out: 18, success: true}
      verifier = %{status: :passed, chain: "todo-code", checks: [%{name: "linear.target_state", status: :passed}]}

      assert :ok =
               Issues.begin_verification(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "todo-code",
                 session_id: "sess-verify",
                 summary: summary
               })

      {:ok, verifying_row} = Issues.get(issue_id)
      assert verifying_row.state == "verifying"

      assert :ok =
               Issues.record_verification_result(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "todo-code",
                 result: verifier
               })

      assert :ok =
               Issues.complete_turn(issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "todo-code",
                 session_id: "sess-verify",
                 summary: summary,
                 verification: verifier,
                 expected_state: "verifying"
               })

      {:ok, row} = Issues.get(issue_id)
      assert row.state == "completed"

      wal = File.read!(State.default_wal_path())
      assert wal =~ "\"kind\":\"verification_passed\""
      assert wal =~ "\"verifier\""
    end

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

  describe "reconcile_stale_turn_running/0" do
    test "downgrades previous-boot turn_running rows to retryable_failed" do
      issue_id = unique_issue_id("stale-running")

      {:ok, %{attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-stale-running")

      {:ok, :ok} =
        State.transaction(fn conn ->
          exec!(conn, "UPDATE issues SET owner_boot_run_id = 0 WHERE issue_id = ?", [issue_id])
        end)

      assert {:ok, %{issue_ids: issue_ids}} = State.reconcile_stale_turn_running()
      assert issue_id in issue_ids

      assert {:ok, row} = Issues.get(issue_id)
      assert row.state == "retryable_failed"
      assert row.last_failure_reason == "stale_turn_running"
      assert is_nil(row.owner_boot_run_id)
      assert is_nil(row.current_turn_id)

      assert {:ok, %{state: "failed", reason: "stale_turn_running"}} =
               fetch_turn_attempt(issue_id, attempt_id)
    end

    test "does not alter current-boot or completed rows" do
      current_issue_id = unique_issue_id("current-running")
      completed_issue_id = unique_issue_id("completed")

      {:ok, _} = Issues.begin_turn(current_issue_id, "c-current-running")

      {:ok, %{turn_id: turn_id, attempt_id: attempt_id}} =
        Issues.begin_turn(completed_issue_id, "c-completed")

      assert :ok =
               Issues.complete_turn(completed_issue_id, %{
                 attempt_id: attempt_id,
                 turn_id: turn_id,
                 chain: "c-completed",
                 session_id: "sess-completed",
                 summary: %{success: true}
               })

      assert {:ok, %{issue_ids: issue_ids}} = State.reconcile_stale_turn_running()
      refute current_issue_id in issue_ids
      refute completed_issue_id in issue_ids

      assert {:ok, current_row} = Issues.get(current_issue_id)
      assert current_row.state == "turn_running"

      assert {:ok, completed_row} = Issues.get(completed_issue_id)
      assert completed_row.state == "completed"
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

  describe "boot stale turn_running reconciliation" do
    test "demotes dead-owner turn_running rows to retryable_failed" do
      issue_id = unique_issue_id("stale-boot")

      {:ok, %{attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-stale-boot")
      dead_boot_run_id = insert_boot_run!(pid: 0)
      set_issue_owner_boot_run!(issue_id, dead_boot_run_id)

      assert {:ok, %{reconciled: reconciled_rows}} =
               Issues.reconcile_stale_turn_running_on_boot(
                 pid_alive?: fn _pid -> false end,
                 now: fn -> 1_000_000 end,
                 rand: fn -> 0.5 end
               )

      assert reconciled = Enum.find(reconciled_rows, &(&1.issue_id == issue_id))
      assert reconciled.issue_id == issue_id
      assert reconciled.state == "retryable_failed"
      assert reconciled.stale_reason == :owner_pid_dead
      assert reconciled.retry_next_at == 1_000_060

      {:ok, row} = Issues.get(issue_id)
      assert row.state == "retryable_failed"
      assert row.last_failure_reason == "stale_owner_boot"
      assert is_nil(row.owner_boot_run_id)
      assert is_nil(row.current_turn_id)

      assert turn_attempt_state(issue_id, attempt_id) == "failed"
    end

    test "skips live-owner turn_running rows and reports DB/runtime mismatch" do
      issue_id = unique_issue_id("live-owner")

      {:ok, _} = Issues.begin_turn(issue_id, "c-live-owner")
      live_boot_run_id = insert_boot_run!(pid: 12_345)
      set_issue_owner_boot_run!(issue_id, live_boot_run_id)

      assert {:ok, %{skipped: skipped_rows}} =
               Issues.reconcile_stale_turn_running_on_boot(
                 pid_alive?: fn 12_345 -> true end,
                 now: fn -> 1_000_000 end,
                 rand: fn -> 0.5 end
               )

      assert skipped = Enum.find(skipped_rows, &(&1.issue_id == issue_id))
      assert skipped.issue_id == issue_id
      assert skipped.skip_reason == :owner_pid_alive

      assert %{issue_id: ^issue_id, owner_status: owner_status} =
               Enum.find(Issues.turn_running_not_in_runtime([]), &(&1.issue_id == issue_id))

      assert owner_status in ["owner_pid_alive", "owner_pid_dead"]
    end
  end

  describe "janitor findings" do
    test "detects running turn attempts whose issue is no longer running" do
      issue_id = unique_issue_id("orphan")
      {:ok, %{attempt_id: attempt_id}} = Issues.begin_turn(issue_id, "c-orphan")

      force_issue_state!(issue_id, "retryable_failed")

      assert [
               %{
                 issue_id: ^issue_id,
                 attempt_id: ^attempt_id,
                 state: "running",
                 issue_state: "retryable_failed",
                 orphan_reason: "issue_state_retryable_failed"
               }
             ] = Issues.orphaned_turn_attempts()
    end
  end

  defp insert_boot_run!(attrs) do
    {:ok, boot_run_id} =
      State.transaction(fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(
            conn,
            "INSERT INTO boot_runs(started_at, pid, hostname) VALUES (?, ?, ?) RETURNING boot_run_id"
          )

        :ok = Sqlite3.bind(stmt, [System.system_time(:second), Keyword.fetch!(attrs, :pid), "test-host"])
        {:row, [boot_run_id]} = Sqlite3.step(conn, stmt)
        :ok = Sqlite3.release(conn, stmt)
        boot_run_id
      end)

    boot_run_id
  end

  defp set_issue_owner_boot_run!(issue_id, boot_run_id) do
    {:ok, :ok} =
      State.transaction(fn conn ->
        exec!(conn, "UPDATE issues SET owner_boot_run_id = ? WHERE issue_id = ?", [boot_run_id, issue_id])
      end)

    :ok
  end

  defp force_issue_state!(issue_id, state) do
    {:ok, :ok} =
      State.transaction(fn conn ->
        exec!(conn, "UPDATE issues SET state = ?, owner_boot_run_id = NULL WHERE issue_id = ?", [
          state,
          issue_id
        ])
      end)

    :ok
  end

  defp turn_attempt_state(issue_id, attempt_id) do
    {:ok, state} =
      State.transaction(fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(
            conn,
            "SELECT state FROM turn_attempts WHERE issue_id = ? AND attempt_id = ?"
          )

        :ok = Sqlite3.bind(stmt, [issue_id, attempt_id])
        {:row, [state]} = Sqlite3.step(conn, stmt)
        :ok = Sqlite3.release(conn, stmt)
        state
      end)

    state
  end

  defp fetch_turn_attempt(issue_id, attempt_id) do
    {:ok, result} =
      State.transaction(fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(
            conn,
            "SELECT state, reason FROM turn_attempts WHERE issue_id = ? AND attempt_id = ?"
          )

        :ok = Sqlite3.bind(stmt, [issue_id, attempt_id])

        result =
          case Sqlite3.step(conn, stmt) do
            {:row, [state, reason]} -> {:ok, %{state: state, reason: reason}}
            :done -> {:error, :not_found}
          end

        :ok = Sqlite3.release(conn, stmt)
        result
      end)

    result
  end

  defp exec!(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end
end
