defmodule SymphonyElixir.State.Migrations do
  @moduledoc """
  PR3 schema v1. Migrations are intentionally written as raw SQL strings (no
  Ecto runtime). Future migrations append to `@migrations` keyed by version.
  """

  alias Exqlite.Sqlite3

  @v1_statements [
    """
    CREATE TABLE IF NOT EXISTS schema_version (
      version    INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS boot_runs (
      boot_run_id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at  INTEGER NOT NULL,
      ended_at    INTEGER,
      pid         INTEGER,
      hostname    TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS fence_counter (
      id       INTEGER PRIMARY KEY CHECK (id = 1),
      next_seq INTEGER NOT NULL DEFAULT 1
    )
    """,
    "INSERT OR IGNORE INTO fence_counter(id, next_seq) VALUES (1, 1)",
    """
    CREATE TABLE IF NOT EXISTS issues (
      issue_id            TEXT PRIMARY KEY,
      chain               TEXT NOT NULL,
      agent               TEXT NOT NULL,
      session_id          TEXT,
      state               TEXT NOT NULL,
      attempt_id          INTEGER NOT NULL DEFAULT 0,
      retry_budget_used   INTEGER NOT NULL DEFAULT 0,
      retry_next_at       INTEGER,
      last_failure_reason TEXT,
      owner_boot_run_id   INTEGER,
      owner_lane          TEXT,
      claim_expires_at    INTEGER,
      fence_seq           INTEGER NOT NULL DEFAULT 0,
      current_turn_id     TEXT,
      started_at          INTEGER NOT NULL,
      last_event_at       INTEGER NOT NULL,
      last_event_kind     TEXT,
      linear_state        TEXT,
      payload_json        TEXT,
      CHECK (state IN (
        'pending', 'claimed', 'lane_ready', 'turn_running', 'turn_ended',
        'verifying', 'completed',
        'retryable_failed', 'rate_limited', 'auth_blocked',
        'quarantined', 'waiting_upstream', 'reconcile_pending'
      ))
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_issues_chain_state ON issues(chain, state)",
    "CREATE INDEX IF NOT EXISTS idx_issues_state ON issues(state)",
    """
    CREATE TABLE IF NOT EXISTS turn_attempts (
      issue_id         TEXT NOT NULL,
      attempt_id       INTEGER NOT NULL,
      turn_id          TEXT NOT NULL,
      lane             TEXT NOT NULL,
      state            TEXT NOT NULL,
      reason           TEXT,
      session_id       TEXT,
      tokens_in        INTEGER,
      tokens_out       INTEGER,
      tool_calls       INTEGER,
      error_class      TEXT,
      fence_seq        INTEGER NOT NULL,
      boot_run_id      INTEGER NOT NULL,
      started_at       INTEGER,
      ended_at         INTEGER,
      raw_summary_json TEXT,
      PRIMARY KEY (issue_id, attempt_id),
      UNIQUE (turn_id),
      FOREIGN KEY (issue_id) REFERENCES issues(issue_id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_turn_attempts_issue ON turn_attempts(issue_id, attempt_id)",
    """
    CREATE TABLE IF NOT EXISTS events (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      ts           INTEGER NOT NULL,
      boot_run_id  INTEGER NOT NULL,
      fence_seq    INTEGER NOT NULL,
      issue_id     TEXT,
      turn_id      TEXT,
      chain        TEXT,
      kind         TEXT NOT NULL,
      payload_json TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_events_issue_ts ON events(issue_id, ts)",
    "CREATE INDEX IF NOT EXISTS idx_events_chain_ts ON events(chain, ts)",
    "CREATE INDEX IF NOT EXISTS idx_events_fence ON events(boot_run_id, fence_seq)"
  ]

  @migrations %{1 => @v1_statements}

  @doc "Apply all pending migrations idempotently."
  @spec migrate(reference()) :: :ok
  def migrate(conn) do
    :ok = Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS schema_version (
      version    INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL
    )
    """)

    @migrations
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn version ->
      if applied?(conn, version) do
        :ok
      else
        apply_version!(conn, version, Map.fetch!(@migrations, version))
      end
    end)

    :ok
  end

  defp applied?(conn, version) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT 1 FROM schema_version WHERE version = ?")
    :ok = Sqlite3.bind(stmt, [version])
    result = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    match?({:row, _}, result)
  end

  defp apply_version!(conn, version, statements) do
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      Enum.each(statements, fn sql -> :ok = Sqlite3.execute(conn, sql) end)

      {:ok, stmt} =
        Sqlite3.prepare(conn, "INSERT INTO schema_version(version, applied_at) VALUES (?, ?)")

      :ok = Sqlite3.bind(stmt, [version, System.system_time(:second)])
      :done = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      :ok = Sqlite3.execute(conn, "COMMIT")
    rescue
      e ->
        :ok = Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end
end
