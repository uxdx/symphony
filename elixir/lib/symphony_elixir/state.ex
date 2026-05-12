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
  alias SymphonyElixir.State.Issues
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
  @spec boot_run_id() :: pos_integer()
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
    ensure_db_path_outside_current_git_checkout!(db_path)
    File.mkdir_p!(Path.dirname(db_path))
    {:ok, conn} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
    :ok = Migrations.migrate(conn)

    boot = insert_boot_run!(conn)
    :persistent_term.put({__MODULE__, :boot_run_id}, boot.boot_run_id)
    {:ok, stale_reconcile} = Issues.reconcile_stale_turn_running_on_boot(conn, boot_run_id: boot.boot_run_id)

    Logger.info("[symphony-state] db=#{db_path} boot_run_id=#{boot.boot_run_id} pid=#{boot.pid} stale_turn_running_reconciled=#{length(stale_reconcile.reconciled)}")

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

  defp ensure_db_path_outside_current_git_checkout!(db_path) do
    with {:ok, cwd} <- File.cwd(),
         {root, 0} <- System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      root = root |> String.trim() |> normalize_path()
      expanded_db_path = normalize_path(db_path)

      if inside_path?(expanded_db_path, root) do
        raise ArgumentError,
              "Symphony state DB path must not be inside the repository checkout: #{expanded_db_path}"
      end
    else
      _ -> :ok
    end
  end

  defp inside_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> String.replace_prefix("/private/var/", "/var/")
    |> String.replace_prefix("/private/tmp/", "/tmp/")
  end

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
