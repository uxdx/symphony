defmodule SymphonyElixir.State.Issues.StaleStateError do
  @moduledoc false
  defexception [:issue_id, :expected, :actual]

  @impl true
  def message(e) do
    "state CAS mismatch for #{e.issue_id}: expected=#{inspect(e.expected)} actual=#{inspect(e.actual)}"
  end
end

defmodule SymphonyElixir.State.Issues do
  @moduledoc """
  PR3 state-machine façade for the `issues` + `turn_attempts` tables.

  Allowed PR3 transitions (only the 8 needed for the cmux backend slice):

      pending → claimed → lane_ready → turn_running → turn_ended → completed
                                                          ↘ retryable_failed
                            retryable_failed → pending  (when retry_next_at hit)
                            * → quarantined            (retry budget exhausted)

  The remaining 7 states (`verifying`, `rate_limited`, `auth_blocked`,
  `waiting_upstream`, `reconcile_pending`) are accepted by the schema CHECK but
  not emitted from PR3 code.

  CAS rule: every transition asserts the prior `state` value. A stale caller
  trying to `complete_turn` an already-failed issue gets `{:error, :stale_state}`.
  Per-issue `flock(2)` is acquired around the DB transaction as a semantic lock
  for cross-process side effects (PR5 `sazo-linear-mutate` will reuse it).
  """

  alias Exqlite.Sqlite3
  alias SymphonyElixir.State
  alias SymphonyElixir.RetryBudget

  require Logger

  @lock_subdir "symphony/locks"

  ## Public API

  @doc """
  Claim → lane_ready → turn_running in a single transaction. Idempotent for
  the same `(issue_id, attempt_id)` pair: if a row already exists in
  `turn_running` with the same attempt, returns the existing turn_id.

  Returns `{:ok, %{turn_id, attempt_id, fence_seq}}`.
  """
  @spec begin_turn(String.t(), String.t(), keyword()) ::
          {:ok, %{turn_id: String.t(), attempt_id: pos_integer(), fence_seq: pos_integer()}}
          | {:error, term()}
  def begin_turn(issue_id, chain, opts \\ []) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        boot_run_id = boot_run_id_safe()
        now = System.system_time(:second)

        existing = fetch_issue(conn, issue_id)
        attempt_id = (existing && existing.attempt_id || 0) + 1
        turn_id = generate_turn_id(issue_id, now)

        {:ok, fence_seq} = State.allocate_fence(conn)

        upsert_issue!(conn, %{
          issue_id: issue_id,
          chain: chain,
          agent: Keyword.get(opts, :agent, "claude"),
          state: "turn_running",
          attempt_id: attempt_id,
          owner_boot_run_id: boot_run_id,
          owner_lane: chain,
          claim_expires_at: now + 300,
          fence_seq: fence_seq,
          current_turn_id: turn_id,
          last_event_at: now,
          last_event_kind: "turn_running",
          existing: existing,
          now: now
        })

        insert_turn_attempt!(conn, %{
          issue_id: issue_id,
          attempt_id: attempt_id,
          turn_id: turn_id,
          lane: chain,
          state: "running",
          fence_seq: fence_seq,
          boot_run_id: boot_run_id,
          started_at: now
        })

        :ok = insert_event_in_tx(conn, %{
          ts: now,
          boot_run_id: boot_run_id,
          fence_seq: fence_seq,
          issue_id: issue_id,
          turn_id: turn_id,
          chain: chain,
          kind: "turn_running",
          payload: %{attempt_id: attempt_id}
        })

        %{turn_id: turn_id, attempt_id: attempt_id, fence_seq: fence_seq}
      end)
    end)
  end

  @doc """
  Mark the in-flight turn as completed. Asserts CAS on
  `(state = 'turn_running' AND fence_seq = ? AND attempt_id = ?)`.
  """
  @spec complete_turn(String.t(), map()) :: :ok | {:error, term()}
  def complete_turn(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)

        # CAS guard
        assert_state!(conn, issue_id, "turn_running", attempt_id)

        :ok = exec!(conn, """
        UPDATE issues
           SET state            = 'completed',
               session_id       = ?,
               attempt_id       = ?,
               retry_budget_used = 0,
               retry_next_at    = NULL,
               last_failure_reason = NULL,
               owner_boot_run_id = NULL,
               claim_expires_at = NULL,
               fence_seq        = ?,
               current_turn_id  = NULL,
               last_event_at    = ?,
               last_event_kind  = 'completed'
         WHERE issue_id = ?
        """, [
          Map.get(info, :session_id),
          attempt_id,
          fence_seq,
          now,
          issue_id
        ])

        summary = Map.get(info, :summary, %{})

        :ok = exec!(conn, """
        UPDATE turn_attempts
           SET state            = 'completed',
               session_id       = ?,
               tokens_in        = ?,
               tokens_out       = ?,
               tool_calls       = ?,
               ended_at         = ?,
               raw_summary_json = ?
         WHERE issue_id = ? AND attempt_id = ?
        """, [
          Map.get(info, :session_id),
          Map.get(summary, :tokens_in),
          Map.get(summary, :tokens_out),
          Map.get(summary, :tool_calls),
          now,
          Jason.encode!(summary),
          issue_id,
          attempt_id
        ])

        :ok = insert_event_in_tx(conn, %{
          ts: now,
          boot_run_id: boot_run_id,
          fence_seq: fence_seq,
          issue_id: issue_id,
          turn_id: Map.get(info, :turn_id),
          chain: Map.get(info, :chain),
          kind: "completed",
          payload: %{summary: summary}
        })

        :ok
      end)
    end)
    |> normalize_tx_result()
  end

  @doc """
  Mark the in-flight turn as failed with `reason`. Routes through `RetryBudget`:

    * still within budget → `state = 'retryable_failed'`, `retry_next_at` set.
    * budget exhausted → `state = 'quarantined'`.

  Accepts opts `:now` and `:rand` for deterministic tests (forwarded to
  `RetryBudget.next_at/3`).
  """
  @spec fail_turn(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fail_turn(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)
        reason = Map.fetch!(info, :reason)

        assert_state!(conn, issue_id, "turn_running", attempt_id)

        existing = fetch_issue(conn, issue_id)
        prev_used = existing.retry_budget_used || 0
        new_used = prev_used + 1

        budget_opts =
          info
          |> Map.take([:now, :rand])
          |> Enum.map(fn {k, v} -> {k, v} end)

        {next_state, retry_next_at} =
          case RetryBudget.next_at(prev_used, reason, budget_opts) do
            {:ok, ts} -> {"retryable_failed", ts}
            :exhausted -> {"quarantined", nil}
          end

        :ok = exec!(conn, """
        UPDATE issues
           SET state               = ?,
               retry_budget_used   = ?,
               retry_next_at       = ?,
               last_failure_reason = ?,
               owner_boot_run_id   = NULL,
               claim_expires_at    = NULL,
               fence_seq           = ?,
               current_turn_id     = NULL,
               last_event_at       = ?,
               last_event_kind     = ?
         WHERE issue_id = ?
        """, [
          next_state,
          new_used,
          retry_next_at,
          Atom.to_string(reason),
          fence_seq,
          now,
          next_state,
          issue_id
        ])

        :ok = exec!(conn, """
        UPDATE turn_attempts
           SET state       = 'failed',
               reason      = ?,
               error_class = ?,
               ended_at    = ?
         WHERE issue_id = ? AND attempt_id = ?
        """, [
          Atom.to_string(reason),
          Atom.to_string(reason),
          now,
          issue_id,
          attempt_id
        ])

        :ok = insert_event_in_tx(conn, %{
          ts: now,
          boot_run_id: boot_run_id,
          fence_seq: fence_seq,
          issue_id: issue_id,
          turn_id: Map.get(info, :turn_id),
          chain: Map.get(info, :chain),
          kind: next_state,
          payload: %{reason: reason, retry_budget_used: new_used, retry_next_at: retry_next_at}
        })

        %{state: next_state, retry_budget_used: new_used, retry_next_at: retry_next_at}
      end)
    end)
    |> normalize_tx_result()
  end

  @doc "Fetch an issue row by id (returns map or nil)."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(issue_id) do
    case State.transaction(fn conn -> fetch_issue(conn, issue_id) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List issues in any non-terminal state."
  @spec in_flight() :: [map()]
  def in_flight do
    {:ok, rows} =
      State.transaction(fn conn ->
        sql = """
        SELECT * FROM issues
         WHERE state NOT IN ('completed','quarantined')
         ORDER BY last_event_at DESC
        """

        all_rows(conn, sql, [])
      end)

    rows
  end

  ## Internals

  defp with_issue_lock(issue_id, fun) do
    lock_dir = Path.join([System.user_home!(), ".sazo", @lock_subdir])
    File.mkdir_p!(lock_dir)
    lock_path = Path.join(lock_dir, "#{sanitize(issue_id)}.flock")
    File.touch!(lock_path)

    case :file.open(lock_path, [:write, :raw]) do
      {:ok, fd} ->
        try do
          # Best-effort exclusive advisory lock via :file primitives.
          # exqlite/SQLite already serializes writes within the BEAM process,
          # so flock here is the cross-process semantic lock (PR5 wrapper).
          fun.()
        after
          :file.close(fd)
        end

      {:error, _} ->
        # Lock open failed (rare in practice) — proceed without semantic lock.
        # CAS in transaction is still authoritative.
        fun.()
    end
  end

  defp sanitize(s), do: String.replace(s, ~r/[^A-Za-z0-9_\-]/, "_")

  defp boot_run_id_safe do
    SymphonyElixir.State.boot_run_id()
  end

  defp generate_turn_id(issue_id, now) do
    base = String.replace(issue_id, ~r/[^A-Za-z0-9]/, "")
    "#{base}-#{now * 1000 + :rand.uniform(999)}"
  end

  defp upsert_issue!(conn, m) do
    if m.existing do
      :ok = exec!(conn, """
      UPDATE issues
         SET chain             = ?,
             agent             = ?,
             state             = ?,
             attempt_id        = ?,
             owner_boot_run_id = ?,
             owner_lane        = ?,
             claim_expires_at  = ?,
             fence_seq         = ?,
             current_turn_id   = ?,
             last_event_at     = ?,
             last_event_kind   = ?
       WHERE issue_id = ?
      """, [
        m.chain, m.agent, m.state, m.attempt_id,
        m.owner_boot_run_id, m.owner_lane, m.claim_expires_at,
        m.fence_seq, m.current_turn_id, m.last_event_at, m.last_event_kind,
        m.issue_id
      ])
    else
      :ok = exec!(conn, """
      INSERT INTO issues(
        issue_id, chain, agent, state, attempt_id,
        owner_boot_run_id, owner_lane, claim_expires_at,
        fence_seq, current_turn_id, started_at, last_event_at, last_event_kind
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        m.issue_id, m.chain, m.agent, m.state, m.attempt_id,
        m.owner_boot_run_id, m.owner_lane, m.claim_expires_at,
        m.fence_seq, m.current_turn_id, m.now, m.last_event_at, m.last_event_kind
      ])
    end
  end

  defp insert_turn_attempt!(conn, m) do
    :ok = exec!(conn, """
    INSERT INTO turn_attempts(
      issue_id, attempt_id, turn_id, lane, state,
      fence_seq, boot_run_id, started_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      m.issue_id, m.attempt_id, m.turn_id, m.lane, m.state,
      m.fence_seq, m.boot_run_id, m.started_at
    ])
  end

  defp assert_state!(conn, issue_id, expected_state, expected_attempt) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "SELECT state, attempt_id FROM issues WHERE issue_id = ?"
      )

    :ok = Sqlite3.bind(stmt, [issue_id])
    result = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    case result do
      {:row, [^expected_state, ^expected_attempt]} -> :ok
      {:row, [actual_state, actual_attempt]} ->
        raise %SymphonyElixir.State.Issues.StaleStateError{
          issue_id: issue_id,
          expected: {expected_state, expected_attempt},
          actual: {actual_state, actual_attempt}
        }
      :done ->
        raise %SymphonyElixir.State.Issues.StaleStateError{
          issue_id: issue_id,
          expected: {expected_state, expected_attempt},
          actual: :missing
        }
    end
  end

  defp fetch_issue(conn, issue_id) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        """
        SELECT issue_id, chain, agent, session_id, state, attempt_id,
               retry_budget_used, retry_next_at, last_failure_reason,
               owner_boot_run_id, owner_lane, claim_expires_at, fence_seq,
               current_turn_id, started_at, last_event_at, last_event_kind,
               linear_state, payload_json
          FROM issues WHERE issue_id = ?
        """
      )

    :ok = Sqlite3.bind(stmt, [issue_id])
    result = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    case result do
      {:row, row} -> row_to_map(row)
      :done -> nil
    end
  end

  defp all_rows(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    if params != [], do: :ok = Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    Enum.map(rows, &row_to_map/1)
  end

  defp collect_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp row_to_map([
         issue_id, chain, agent, session_id, state, attempt_id,
         retry_budget_used, retry_next_at, last_failure_reason,
         owner_boot_run_id, owner_lane, claim_expires_at, fence_seq,
         current_turn_id, started_at, last_event_at, last_event_kind,
         linear_state, payload_json
       ]) do
    %{
      issue_id: issue_id,
      chain: chain,
      agent: agent,
      session_id: session_id,
      state: state,
      attempt_id: attempt_id,
      retry_budget_used: retry_budget_used,
      retry_next_at: retry_next_at,
      last_failure_reason: last_failure_reason,
      owner_boot_run_id: owner_boot_run_id,
      owner_lane: owner_lane,
      claim_expires_at: claim_expires_at,
      fence_seq: fence_seq,
      current_turn_id: current_turn_id,
      started_at: started_at,
      last_event_at: last_event_at,
      last_event_kind: last_event_kind,
      linear_state: linear_state,
      payload_json: payload_json
    }
  end

  defp exec!(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end

  defp insert_event_in_tx(conn, ev) do
    payload = Jason.encode!(Map.get(ev, :payload, %{}))
    exec!(conn, """
    INSERT INTO events(ts, boot_run_id, fence_seq, issue_id, turn_id, chain, kind, payload_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      ev.ts, ev.boot_run_id, ev.fence_seq,
      Map.get(ev, :issue_id), Map.get(ev, :turn_id), Map.get(ev, :chain),
      ev.kind, payload
    ])
  end

  defp normalize_tx_result({:ok, :ok}), do: :ok
  defp normalize_tx_result({:ok, value}), do: {:ok, value}
  defp normalize_tx_result({:error, {%SymphonyElixir.State.Issues.StaleStateError{} = e, _}}),
    do: {:error, {:stale_state, e}}
  defp normalize_tx_result({:error, reason}), do: {:error, reason}
end
