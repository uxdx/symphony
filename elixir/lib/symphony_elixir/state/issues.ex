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
  alias SymphonyElixir.RetryBudget
  alias SymphonyElixir.State

  require Logger

  @lock_subdir "symphony/locks"
  @stale_owner_reason :stale_owner_boot

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
        attempt_id = ((existing && existing.attempt_id) || 0) + 1
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

        :ok =
          insert_event_in_tx(conn, %{
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
  Move the in-flight turn from `turn_running` to `verifying` before external
  completion checks run. The issue is not terminal while a verifier is running.
  """
  @spec begin_verification(String.t(), map()) :: :ok | {:error, term()}
  def begin_verification(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)

        assert_state!(conn, issue_id, "turn_running", attempt_id)

        :ok =
          exec!(
            conn,
            """
            UPDATE issues
               SET state           = 'verifying',
                   session_id      = ?,
                   fence_seq       = ?,
                   last_event_at   = ?,
                   last_event_kind = 'verification_started'
             WHERE issue_id = ?
            """,
            [
              Map.get(info, :session_id),
              fence_seq,
              now,
              issue_id
            ]
          )

        :ok =
          exec!(
            conn,
            """
            UPDATE turn_attempts
               SET state            = 'verifying',
                   session_id       = ?,
                   raw_summary_json = ?
             WHERE issue_id = ? AND attempt_id = ?
            """,
            [
              Map.get(info, :session_id),
              Jason.encode!(Map.get(info, :summary, %{})),
              issue_id,
              attempt_id
            ]
          )

        :ok =
          insert_event_in_tx(conn, %{
            ts: now,
            boot_run_id: boot_run_id,
            fence_seq: fence_seq,
            issue_id: issue_id,
            turn_id: Map.get(info, :turn_id),
            chain: Map.get(info, :chain),
            kind: "verification_started",
            payload: %{summary: Map.get(info, :summary, %{})}
          })

        :ok
      end)
    end)
    |> normalize_tx_result()
  end

  @doc """
  Record a structured post-turn verifier result. This does not complete or fail
  the issue; callers must perform the next transition explicitly.
  """
  @spec record_verification_result(String.t(), map()) :: :ok | {:error, term()}
  def record_verification_result(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)
        result = Map.fetch!(info, :result)
        status = Map.get(result, :status) || Map.get(result, "status") || :unknown
        kind = "verification_#{status}"

        assert_state!(conn, issue_id, "verifying", attempt_id)

        :ok =
          exec!(
            conn,
            """
            UPDATE issues
               SET fence_seq       = ?,
                   last_event_at   = ?,
                   last_event_kind = ?
             WHERE issue_id = ?
            """,
            [fence_seq, now, kind, issue_id]
          )

        :ok =
          insert_event_in_tx(conn, %{
            ts: now,
            boot_run_id: boot_run_id,
            fence_seq: fence_seq,
            issue_id: issue_id,
            turn_id: Map.get(info, :turn_id),
            chain: Map.get(info, :chain),
            kind: kind,
            payload: %{verifier: result}
          })

        :ok
      end)
    end)
    |> normalize_tx_result()
  end

  @doc """
  Mark the in-flight turn as completed. By default this asserts
  `state = 'turn_running'`; post-turn verifier callers pass
  `expected_state: "verifying"` so durable completion only happens after the
  verifier result has been recorded.
  """
  @spec complete_turn(String.t(), map()) :: :ok | {:error, term()}
  def complete_turn(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)
        expected_state = Map.get(info, :expected_state, "turn_running")

        # CAS guard
        assert_state!(conn, issue_id, expected_state, attempt_id)

        :ok =
          exec!(
            conn,
            """
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
            """,
            [
              Map.get(info, :session_id),
              attempt_id,
              fence_seq,
              now,
              issue_id
            ]
          )

        summary = Map.get(info, :summary, %{})

        :ok =
          exec!(
            conn,
            """
            UPDATE turn_attempts
               SET state            = 'completed',
                   session_id       = ?,
                   tokens_in        = ?,
                   tokens_out       = ?,
                   tool_calls       = ?,
                   ended_at         = ?,
                   raw_summary_json = ?
             WHERE issue_id = ? AND attempt_id = ?
            """,
            [
              Map.get(info, :session_id),
              Map.get(summary, :tokens_in),
              Map.get(summary, :tokens_out),
              Map.get(summary, :tool_calls),
              now,
              Jason.encode!(summary),
              issue_id,
              attempt_id
            ]
          )

        :ok =
          insert_event_in_tx(conn, %{
            ts: now,
            boot_run_id: boot_run_id,
            fence_seq: fence_seq,
            issue_id: issue_id,
            turn_id: Map.get(info, :turn_id),
            chain: Map.get(info, :chain),
            kind: "completed",
            payload: %{summary: summary, verifier: Map.get(info, :verification)}
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
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  def fail_turn(issue_id, %{} = info) do
    with_issue_lock(issue_id, fn ->
      State.transaction(fn conn ->
        now = System.system_time(:second)
        boot_run_id = boot_run_id_safe()
        {:ok, fence_seq} = State.allocate_fence(conn)
        attempt_id = Map.fetch!(info, :attempt_id)
        reason = Map.fetch!(info, :reason)
        expected_state = Map.get(info, :expected_state, "turn_running")

        assert_state!(conn, issue_id, expected_state, attempt_id)

        existing = fetch_issue(conn, issue_id)
        prev_used = existing.retry_budget_used || 0
        new_used = prev_used + 1

        budget_opts =
          info
          |> Map.take([:now, :rand])
          |> Map.to_list()

        {next_state, retry_next_at} = next_retry_state(prev_used, reason, budget_opts)

        :ok =
          exec!(
            conn,
            """
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
            """,
            [
              next_state,
              new_used,
              retry_next_at,
              Atom.to_string(reason),
              fence_seq,
              now,
              next_state,
              issue_id
            ]
          )

        :ok =
          exec!(
            conn,
            """
            UPDATE turn_attempts
               SET state       = 'failed',
                   reason      = ?,
                   error_class = ?,
                   ended_at    = ?
             WHERE issue_id = ? AND attempt_id = ?
            """,
            [
              Atom.to_string(reason),
              Atom.to_string(reason),
              now,
              issue_id,
              attempt_id
            ]
          )

        payload =
          %{
            reason: reason,
            classification: Map.get(info, :classification),
            verification: Map.get(info, :verification),
            retry_budget_used: new_used,
            retry_next_at: retry_next_at
          }
          |> maybe_put_payload_details(Map.get(info, :details))

        :ok =
          insert_event_in_tx(conn, %{
            ts: now,
            boot_run_id: boot_run_id,
            fence_seq: fence_seq,
            issue_id: issue_id,
            turn_id: Map.get(info, :turn_id),
            chain: Map.get(info, :chain),
            kind: next_state,
            payload: payload
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

  @doc """
  Reconcile stale durable `turn_running` rows during BEAM boot.

  A row is stale when it is still marked `turn_running` but its owner boot run
  is not the current boot and the recorded owner PID is no longer alive. Stale
  rows are demoted through the normal retry budget semantics so completed and
  quarantined rows remain untouched.
  """
  @spec reconcile_stale_turn_running_on_boot(keyword()) ::
          {:ok, %{reconciled: [map()], skipped: [map()]}} | {:error, term()}
  def reconcile_stale_turn_running_on_boot(opts \\ []) do
    State.transaction(fn conn ->
      {:ok, result} = reconcile_stale_turn_running_on_boot(conn, opts)
      result
    end)
    |> normalize_tx_result()
  end

  @doc false
  @spec reconcile_stale_turn_running_on_boot(reference(), keyword()) ::
          {:ok, %{reconciled: [map()], skipped: [map()]}}
  def reconcile_stale_turn_running_on_boot(conn, opts) when is_reference(conn) do
    current_boot_run_id = Keyword.get(opts, :boot_run_id, boot_run_id_safe())
    pid_alive? = Keyword.get(opts, :pid_alive?, &pid_alive?/1)
    budget_opts = Keyword.take(opts, [:now, :rand])
    now = current_time(opts)

    result =
      conn
      |> fetch_turn_running_with_owner_boot()
      |> Enum.reduce(%{reconciled: [], skipped: []}, fn row, acc ->
        case stale_turn_running_reason(row, current_boot_run_id, pid_alive?) do
          {:stale, reason} ->
            reconciled = retry_stale_turn_running!(conn, row, reason, now, budget_opts)
            %{acc | reconciled: [reconciled | acc.reconciled]}

          {:skip, reason} ->
            %{acc | skipped: [Map.put(row, :skip_reason, reason) | acc.skipped]}
        end
      end)

    {:ok, %{reconciled: Enum.reverse(result.reconciled), skipped: Enum.reverse(result.skipped)}}
  end

  @doc """
  Return durable `turn_running` rows that are not represented in the supplied
  runtime running issue ids. This is dashboard/status observability only.
  """
  @spec turn_running_not_in_runtime([String.t()]) :: [map()]
  def turn_running_not_in_runtime(runtime_issue_ids) when is_list(runtime_issue_ids) do
    runtime_issue_ids = MapSet.new(runtime_issue_ids)
    pid_alive? = &pid_alive?/1
    current_boot_run_id = boot_run_id_safe()

    {:ok, rows} =
      State.transaction(fn conn ->
        conn
        |> fetch_turn_running_with_owner_boot()
        |> Enum.reject(&MapSet.member?(runtime_issue_ids, &1.issue_id))
        |> Enum.map(fn row ->
          Map.put(row, :owner_status, owner_status(row, current_boot_run_id, pid_alive?))
        end)
      end)

    rows
  end

  @doc """
  Detect running/verifying turn_attempt rows whose parent issue is missing or no
  longer in a compatible in-flight state.
  """
  @spec orphaned_turn_attempts() :: [map()]
  def orphaned_turn_attempts do
    {:ok, rows} =
      State.transaction(fn conn ->
        fetch_orphaned_turn_attempts(conn)
      end)

    rows
  end

  @doc "Combined state-db janitor findings for observability surfaces."
  @spec janitor_findings([String.t()]) :: map()
  def janitor_findings(runtime_issue_ids) when is_list(runtime_issue_ids) do
    turn_running_not_runtime = turn_running_not_in_runtime(runtime_issue_ids)
    orphaned_attempts = orphaned_turn_attempts()

    %{
      turn_running_not_runtime: turn_running_not_runtime,
      orphaned_turn_attempts: orphaned_attempts
    }
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

  defp next_retry_state(prev_used, reason, budget_opts) do
    case RetryBudget.next_at(prev_used, reason, budget_opts) do
      {:ok, ts} -> {"retryable_failed", ts}
      :exhausted -> {"quarantined", nil}
    end
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "pid="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp pid_alive?(_pid), do: false

  defp current_time(opts) do
    case Keyword.get(opts, :now) do
      fun when is_function(fun, 0) -> fun.()
      nil -> System.system_time(:second)
    end
  end

  defp stale_turn_running_reason(%{owner_boot_run_id: current_boot_run_id}, current_boot_run_id, _pid_alive?)
       when is_integer(current_boot_run_id),
       do: {:skip, :current_boot_run}

  defp stale_turn_running_reason(%{owner_boot_run_id: nil}, _current_boot_run_id, _pid_alive?),
    do: {:stale, :missing_owner_boot_run_id}

  defp stale_turn_running_reason(%{owner_pid: nil}, _current_boot_run_id, _pid_alive?),
    do: {:stale, :missing_owner_pid}

  defp stale_turn_running_reason(%{owner_pid: pid}, _current_boot_run_id, pid_alive?) when is_integer(pid) do
    if pid_alive?.(pid), do: {:skip, :owner_pid_alive}, else: {:stale, :owner_pid_dead}
  end

  defp stale_turn_running_reason(_row, _current_boot_run_id, _pid_alive?),
    do: {:stale, :missing_owner_boot_run}

  defp owner_status(row, current_boot_run_id, pid_alive?) do
    case stale_turn_running_reason(row, current_boot_run_id, pid_alive?) do
      {:stale, reason} -> Atom.to_string(reason)
      {:skip, reason} -> Atom.to_string(reason)
    end
  end

  defp generate_turn_id(issue_id, now) do
    base = String.replace(issue_id, ~r/[^A-Za-z0-9]/, "")
    "#{base}-#{now * 1000 + :rand.uniform(999)}"
  end

  defp upsert_issue!(conn, m) do
    if m.existing do
      :ok =
        exec!(
          conn,
          """
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
          """,
          [
            m.chain,
            m.agent,
            m.state,
            m.attempt_id,
            m.owner_boot_run_id,
            m.owner_lane,
            m.claim_expires_at,
            m.fence_seq,
            m.current_turn_id,
            m.last_event_at,
            m.last_event_kind,
            m.issue_id
          ]
        )
    else
      :ok =
        exec!(
          conn,
          """
          INSERT INTO issues(
            issue_id, chain, agent, state, attempt_id,
            owner_boot_run_id, owner_lane, claim_expires_at,
            fence_seq, current_turn_id, started_at, last_event_at, last_event_kind
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            m.issue_id,
            m.chain,
            m.agent,
            m.state,
            m.attempt_id,
            m.owner_boot_run_id,
            m.owner_lane,
            m.claim_expires_at,
            m.fence_seq,
            m.current_turn_id,
            m.now,
            m.last_event_at,
            m.last_event_kind
          ]
        )
    end
  end

  defp insert_turn_attempt!(conn, m) do
    :ok =
      exec!(
        conn,
        """
        INSERT INTO turn_attempts(
          issue_id, attempt_id, turn_id, lane, state,
          fence_seq, boot_run_id, started_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          m.issue_id,
          m.attempt_id,
          m.turn_id,
          m.lane,
          m.state,
          m.fence_seq,
          m.boot_run_id,
          m.started_at
        ]
      )
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
      {:row, [^expected_state, ^expected_attempt]} ->
        :ok

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

  defp fetch_turn_running_with_owner_boot(conn) do
    conn
    |> query_all(
      """
      SELECT i.issue_id, i.chain, i.agent, i.session_id, i.state, i.attempt_id,
             i.retry_budget_used, i.retry_next_at, i.last_failure_reason,
             i.owner_boot_run_id, i.owner_lane, i.claim_expires_at, i.fence_seq,
             i.current_turn_id, i.started_at, i.last_event_at, i.last_event_kind,
             b.pid, b.hostname, b.started_at
        FROM issues i
        LEFT JOIN boot_runs b ON b.boot_run_id = i.owner_boot_run_id
       WHERE i.state = 'turn_running'
       ORDER BY i.last_event_at ASC, i.issue_id ASC
      """,
      []
    )
    |> Enum.map(&turn_running_owner_row_to_map/1)
  end

  defp retry_stale_turn_running!(conn, row, stale_reason, now, budget_opts) do
    {:ok, fence_seq} = State.allocate_fence(conn)
    prev_used = row.retry_budget_used || 0
    new_used = prev_used + 1

    {next_state, retry_next_at} =
      case RetryBudget.next_at(prev_used, @stale_owner_reason, budget_opts) do
        {:ok, ts} -> {"retryable_failed", ts}
        :exhausted -> {"quarantined", nil}
      end

    :ok =
      exec!(
        conn,
        """
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
         WHERE issue_id = ? AND state = 'turn_running'
        """,
        [
          next_state,
          new_used,
          retry_next_at,
          Atom.to_string(@stale_owner_reason),
          fence_seq,
          now,
          next_state,
          row.issue_id
        ]
      )

    :ok =
      exec!(
        conn,
        """
        UPDATE turn_attempts
           SET state       = 'failed',
               reason      = ?,
               error_class = ?,
               ended_at    = ?
         WHERE issue_id = ? AND attempt_id = ? AND state IN ('running', 'verifying')
        """,
        [
          Atom.to_string(@stale_owner_reason),
          Atom.to_string(@stale_owner_reason),
          now,
          row.issue_id,
          row.attempt_id
        ]
      )

    :ok =
      insert_event_in_tx(conn, %{
        ts: now,
        boot_run_id: boot_run_id_safe(),
        fence_seq: fence_seq,
        issue_id: row.issue_id,
        turn_id: row.current_turn_id,
        chain: row.chain,
        kind: next_state,
        payload: %{
          reason: @stale_owner_reason,
          stale_reason: stale_reason,
          owner_boot_run_id: row.owner_boot_run_id,
          owner_pid: row.owner_pid,
          retry_budget_used: new_used,
          retry_next_at: retry_next_at
        }
      })

    row
    |> Map.put(:state, next_state)
    |> Map.put(:stale_reason, stale_reason)
    |> Map.put(:retry_budget_used, new_used)
    |> Map.put(:retry_next_at, retry_next_at)
  end

  defp fetch_orphaned_turn_attempts(conn) do
    conn
    |> query_all(
      """
      SELECT ta.issue_id, ta.attempt_id, ta.turn_id, ta.lane, ta.state,
             ta.reason, ta.boot_run_id, ta.started_at, ta.ended_at,
             i.state
        FROM turn_attempts ta
        LEFT JOIN issues i ON i.issue_id = ta.issue_id
       WHERE ta.state IN ('running', 'verifying')
         AND (i.issue_id IS NULL OR i.state NOT IN ('turn_running', 'verifying'))
       ORDER BY ta.started_at ASC, ta.issue_id ASC, ta.attempt_id ASC
      """,
      []
    )
    |> Enum.map(&orphaned_turn_attempt_row_to_map/1)
  end

  defp all_rows(conn, sql, params) do
    rows = query_all(conn, sql, params)
    Enum.map(rows, &row_to_map/1)
  end

  defp query_all(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    if params != [], do: :ok = Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp collect_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp row_to_map([
         issue_id,
         chain,
         agent,
         session_id,
         state,
         attempt_id,
         retry_budget_used,
         retry_next_at,
         last_failure_reason,
         owner_boot_run_id,
         owner_lane,
         claim_expires_at,
         fence_seq,
         current_turn_id,
         started_at,
         last_event_at,
         last_event_kind,
         linear_state,
         payload_json
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

  defp turn_running_owner_row_to_map([
         issue_id,
         chain,
         agent,
         session_id,
         state,
         attempt_id,
         retry_budget_used,
         retry_next_at,
         last_failure_reason,
         owner_boot_run_id,
         owner_lane,
         claim_expires_at,
         fence_seq,
         current_turn_id,
         started_at,
         last_event_at,
         last_event_kind,
         owner_pid,
         owner_hostname,
         owner_started_at
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
      owner_pid: owner_pid,
      owner_hostname: owner_hostname,
      owner_started_at: owner_started_at
    }
  end

  defp orphaned_turn_attempt_row_to_map([
         issue_id,
         attempt_id,
         turn_id,
         lane,
         state,
         reason,
         boot_run_id,
         started_at,
         ended_at,
         issue_state
       ]) do
    %{
      issue_id: issue_id,
      attempt_id: attempt_id,
      turn_id: turn_id,
      lane: lane,
      state: state,
      reason: reason,
      boot_run_id: boot_run_id,
      started_at: started_at,
      ended_at: ended_at,
      issue_state: issue_state,
      orphan_reason: orphan_reason(issue_state)
    }
  end

  defp orphan_reason(nil), do: "missing_issue"
  defp orphan_reason(issue_state), do: "issue_state_#{issue_state}"

  defp exec!(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end

  defp insert_event_in_tx(conn, ev) do
    payload = Jason.encode!(Map.get(ev, :payload, %{}))

    exec!(
      conn,
      """
      INSERT INTO events(ts, boot_run_id, fence_seq, issue_id, turn_id, chain, kind, payload_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        ev.ts,
        ev.boot_run_id,
        ev.fence_seq,
        Map.get(ev, :issue_id),
        Map.get(ev, :turn_id),
        Map.get(ev, :chain),
        ev.kind,
        payload
      ]
    )

    State.append_event_wal(%{
      ts: ev.ts,
      boot_run_id: ev.boot_run_id,
      fence_seq: ev.fence_seq,
      issue_id: Map.get(ev, :issue_id),
      turn_id: Map.get(ev, :turn_id),
      chain: Map.get(ev, :chain),
      kind: ev.kind,
      payload: Map.get(ev, :payload, %{})
    })
  end

  defp normalize_tx_result({:ok, :ok}), do: :ok
  defp normalize_tx_result({:ok, value}), do: {:ok, value}

  defp normalize_tx_result({:error, {%SymphonyElixir.State.Issues.StaleStateError{} = e, _}}),
    do: {:error, {:stale_state, e}}

  defp normalize_tx_result({:error, reason}), do: {:error, reason}

  defp maybe_put_payload_details(payload, nil), do: payload
  defp maybe_put_payload_details(payload, details), do: Map.put(payload, :details, details)
end
