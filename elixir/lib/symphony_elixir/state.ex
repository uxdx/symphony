defmodule SymphonyElixir.State do
  @moduledoc """
  PR3 SQLite-backed durable state for Symphony orchestrator.

  Schema lives in `~/.sazo/symphony/state.db` (overridable via `:db_path`
  start_link option, primarily for tests). Single-writer GenServer guards the
  connection — concurrent writers are not part of PR3.

  PR6 adds a JSONL WAL at `<db_dir>/events.jsonl` — every event written to
  the `events` table is also appended as a JSON line. External tools can
  `tail -f` this file for real-time event streaming.

  PR3/PR6 contract:
    * boot_runs INSERT on start_link
    * fence_counter monotonic via `allocate_fence/0`
    * issues / turn_attempts / events tables (see `SymphonyElixir.State.Migrations`)
    * 15-state CHECK constraint (see schema)
    * record_event/1 and Issues.insert_event_in_tx/2 both write SQLite + WAL
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.State.Migrations

  require Logger

  @default_db_subpath "symphony/state.db"

  defmodule Boot do
    @moduledoc false
    defstruct [:boot_run_id, :started_at, :pid, :hostname]
  end

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolved DB path. Honours `Application.get_env(:symphony_elixir, :state_db_path)`
  (test/dev override) before falling back to `~/.sazo/symphony/state.db`.
  """
  @spec default_db_path() :: Path.t()
  def default_db_path do
    case Application.get_env(:symphony_elixir, :state_db_path) do
      nil -> Path.join([System.user_home!(), ".sazo", @default_db_subpath])
      path -> path
    end
  end

  @doc """
  JSONL WAL path — same directory as the DB, filename `events.jsonl`.
  Inherits the same test override as `default_db_path/0`.
  """
  @spec default_wal_path() :: Path.t()
  def default_wal_path do
    Path.join(Path.dirname(default_db_path()), "events.jsonl")
  end

  @doc """
  Append one event as a JSON line to the JSONL WAL. Best-effort:
  file errors are logged but never propagate to the caller.
  """
  @spec append_event_wal(map()) :: :ok
  def append_event_wal(ev) do
    path = default_wal_path()

    try do
      line = Jason.encode!(ev) <> "\n"
      File.write(path, line, [:append])
    rescue
      e -> Logger.warning("[state_wal] failed to append event: #{inspect(e)}")
    end

    :ok
  end

  @doc """
  Current boot_run_id (allocated at GenServer init). Reads from `:persistent_term`
  so it is safe to call from within a `transaction/2` callback (which runs on
  the State process and would otherwise deadlock on a self-call).
  """
  @spec boot_run_id() :: non_neg_integer()
  @spec boot_run_id(GenServer.name()) :: non_neg_integer()
  def boot_run_id(_server \\ __MODULE__) do
    :persistent_term.get({__MODULE__, :boot_run_id}, 0)
  end

  @doc """
  Run a function inside an `IMMEDIATE` SQLite transaction.

  The function receives the raw `Exqlite.Sqlite3` connection reference. Returns
  `{:ok, result}` on commit or `{:error, reason}` on rollback (the function may
  raise to roll back).
  """
  @spec transaction((reference() -> any())) :: {:ok, any()} | {:error, term()}
  @spec transaction(GenServer.name(), (reference() -> any())) :: {:ok, any()} | {:error, term()}
  def transaction(server \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(server, {:transaction, fun}, 30_000)
  end

  @doc "Allocate next fence_seq inside the current transaction (helper)."
  @spec allocate_fence(reference()) :: {:ok, pos_integer()}
  def allocate_fence(conn) do
    :ok = Sqlite3.execute(conn, "UPDATE fence_counter SET next_seq = next_seq + 1 WHERE id = 1")
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT next_seq - 1 FROM fence_counter WHERE id = 1")
    {:row, [seq]} = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:ok, seq}
  end

  @doc """
  Reconcile stale `turn_running` rows owned by a previous BEAM boot.

  The current boot owns all live turns. Any persisted `turn_running` row whose
  `owner_boot_run_id` differs from the current boot is an orphan from a crashed
  or stopped process and is downgraded to `retryable_failed`.
  """
  @spec reconcile_stale_turn_running() :: {:ok, %{count: non_neg_integer(), issue_ids: [String.t()]}} | {:error, term()}
  def reconcile_stale_turn_running do
    current_boot_run_id = boot_run_id()

    transaction(fn conn ->
      reconcile_stale_turn_running!(conn, current_boot_run_id, "manual")
    end)
  end

  @doc """
  Append an event row. Caller passes the active connection (inside a transaction)
  or `nil` to acquire a new one. fence_seq must be already allocated by caller.
  """
  @spec record_event(reference() | nil, map()) :: :ok
  def record_event(conn, %{} = ev) when is_reference(conn) do
    insert_event!(conn, ev)
  end

  def record_event(nil, %{} = ev) do
    {:ok, _} =
      transaction(fn conn ->
        insert_event!(conn, ev)
      end)

    :ok
  end

  ## GenServer

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())
    File.mkdir_p!(Path.dirname(db_path))
    {:ok, conn} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
    :ok = Migrations.migrate(conn)

    boot = insert_boot_run!(conn)
    :persistent_term.put({__MODULE__, :boot_run_id}, boot.boot_run_id)
    stale = reconcile_stale_turn_running!(conn, boot.boot_run_id, "boot")

    Logger.info("[symphony-state] db=#{db_path} boot_run_id=#{boot.boot_run_id} pid=#{boot.pid}")

    if stale.count > 0 do
      Logger.warning("[symphony-state] reconciled #{stale.count} stale turn_running row(s)")
    end

    {:ok, %{conn: conn, db_path: db_path, boot: boot}}
  end

  @impl true
  def handle_call({:transaction, fun}, _from, state) do
    :ok = Sqlite3.execute(state.conn, "BEGIN IMMEDIATE")

    result =
      try do
        {:committed, fun.(state.conn)}
      rescue
        e -> {:rollback, {e, __STACKTRACE__}}
      catch
        kind, reason -> {:rollback, {kind, reason, __STACKTRACE__}}
      end

    case result do
      {:committed, value} ->
        :ok = Sqlite3.execute(state.conn, "COMMIT")
        {:reply, {:ok, value}, state}

      {:rollback, info} ->
        :ok = Sqlite3.execute(state.conn, "ROLLBACK")
        {:reply, {:error, info}, state}
    end
  end

  ## Internals

  defp insert_boot_run!(conn) do
    pid_int = String.to_integer(System.pid())

    hostname =
      case :inet.gethostname() do
        {:ok, h} -> List.to_string(h)
        _ -> "unknown"
      end

    started_at = System.system_time(:second)

    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO boot_runs(started_at, pid, hostname) VALUES (?, ?, ?) RETURNING boot_run_id"
      )

    :ok = Sqlite3.bind(stmt, [started_at, pid_int, hostname])
    {:row, [boot_run_id]} = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    %Boot{
      boot_run_id: boot_run_id,
      started_at: started_at,
      pid: pid_int,
      hostname: hostname
    }
  end

  defp reconcile_stale_turn_running!(conn, current_boot_run_id, reconciled_by) do
    now = System.system_time(:second)
    rows = stale_turn_running_rows(conn, current_boot_run_id)

    Enum.each(rows, fn row ->
      {:ok, fence_seq} = allocate_fence(conn)

      :ok =
        update_stale_issue!(
          conn,
          row.issue_id,
          row.attempt_id,
          fence_seq,
          now
        )

      :ok = update_stale_turn_attempt!(conn, row.issue_id, row.attempt_id, now)

      insert_event!(conn, %{
        ts: now,
        boot_run_id: current_boot_run_id,
        fence_seq: fence_seq,
        issue_id: row.issue_id,
        turn_id: row.current_turn_id,
        chain: row.chain,
        kind: "retryable_failed",
        payload: %{
          reason: :stale_turn_running,
          details: %{
            reconciled_by: reconciled_by,
            previous_owner_boot_run_id: row.owner_boot_run_id,
            attempt_id: row.attempt_id
          }
        }
      })
    end)

    %{count: length(rows), issue_ids: Enum.map(rows, & &1.issue_id)}
  end

  defp stale_turn_running_rows(conn, current_boot_run_id) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        """
        SELECT issue_id, chain, attempt_id, owner_boot_run_id, current_turn_id
          FROM issues
         WHERE state = 'turn_running'
           AND (owner_boot_run_id IS NULL OR owner_boot_run_id != ?)
         ORDER BY last_event_at ASC
        """
      )

    :ok = Sqlite3.bind(stmt, [current_boot_run_id])
    rows = collect_stale_turn_rows(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp collect_stale_turn_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, [issue_id, chain, attempt_id, owner_boot_run_id, current_turn_id]} ->
        collect_stale_turn_rows(conn, stmt, [
          %{
            issue_id: issue_id,
            chain: chain,
            attempt_id: attempt_id,
            owner_boot_run_id: owner_boot_run_id,
            current_turn_id: current_turn_id
          }
          | acc
        ])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp update_stale_issue!(conn, issue_id, attempt_id, fence_seq, now) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        """
        UPDATE issues
           SET state               = 'retryable_failed',
               retry_next_at       = ?,
               last_failure_reason = 'stale_turn_running',
               owner_boot_run_id   = NULL,
               claim_expires_at    = NULL,
               fence_seq           = ?,
               current_turn_id     = NULL,
               last_event_at       = ?,
               last_event_kind     = 'retryable_failed'
         WHERE issue_id = ? AND attempt_id = ? AND state = 'turn_running'
        """
      )

    :ok = Sqlite3.bind(stmt, [now, fence_seq, now, issue_id, attempt_id])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
  end

  defp update_stale_turn_attempt!(conn, issue_id, attempt_id, now) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        """
        UPDATE turn_attempts
           SET state       = 'failed',
               reason      = 'stale_turn_running',
               error_class = 'stale_turn_running',
               ended_at    = ?
         WHERE issue_id = ? AND attempt_id = ?
        """
      )

    :ok = Sqlite3.bind(stmt, [now, issue_id, attempt_id])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
  end

  defp insert_event!(conn, ev) do
    payload = Jason.encode!(Map.get(ev, :payload, %{}))
    ts = Map.get(ev, :ts, System.system_time(:second))
    boot_run_id = Map.fetch!(ev, :boot_run_id)
    fence_seq = Map.fetch!(ev, :fence_seq)
    kind = Map.fetch!(ev, :kind)
    issue_id = Map.get(ev, :issue_id)
    turn_id = Map.get(ev, :turn_id)
    chain = Map.get(ev, :chain)

    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        """
        INSERT INTO events(ts, boot_run_id, fence_seq, issue_id, turn_id, chain, kind, payload_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
      )

    :ok =
      Sqlite3.bind(stmt, [ts, boot_run_id, fence_seq, issue_id, turn_id, chain, kind, payload])

    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    append_event_wal(%{
      ts: ts,
      boot_run_id: boot_run_id,
      fence_seq: fence_seq,
      issue_id: issue_id,
      turn_id: turn_id,
      chain: chain,
      kind: kind,
      payload: Map.get(ev, :payload, %{})
    })

    :ok
  end
end
