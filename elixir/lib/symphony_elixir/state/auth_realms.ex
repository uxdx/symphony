defmodule SymphonyElixir.State.AuthRealms do
  @moduledoc """
  PR4 realm-level auth + rate-limit state.

  A realm (e.g. "claude:default") is a shared authentication scope. All chains
  that share a keychain/profile belong to the same realm.

  State machine:
    healthy ──auth_revoked──▶ blocked(blocked_until)
    blocked ──TTL expired──▶ healthy  (auto-expire on check)
    blocked ──unblock/1──▶ healthy   (manual recovery)

  Rate-limit is orthogonal: throttled_until is set independently of status.

  Backoff for repeated block events:
    block_count 0 → 30 min
    block_count 1 → 60 min
    block_count 2 → 120 min
    block_count 3+ → 240 min (cap)
  """

  alias Exqlite.Sqlite3
  alias SymphonyElixir.State

  require Logger

  @default_realm "claude:default"
  @block_backoff_sec [1800, 3600, 7200, 14_400]

  @doc "The realm id used for all claude-backed chains."
  @spec default_realm() :: String.t()
  def default_realm, do: @default_realm

  @doc """
  Check realm admission. Auto-expires TTL-elapsed blocks in place.

  Returns:
    :ok                              — realm healthy, turn may proceed
    {:blocked, blocked_until_sec}    — auth blocked until that unix timestamp
    {:throttled, throttled_until_sec}— rate-limited until that unix timestamp
  """
  @spec check(String.t()) :: :ok | {:blocked, integer()} | {:throttled, integer()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def check(realm_id) do
    now = System.system_time(:second)

    case State.transaction(fn conn -> fetch_realm(conn, realm_id) end) do
      {:ok, nil} ->
        :ok

      {:ok, realm} ->
        cond do
          realm.throttled_until && realm.throttled_until > now ->
            {:throttled, realm.throttled_until}

          realm.status == "blocked" && realm.blocked_until && realm.blocked_until > now ->
            {:blocked, realm.blocked_until}

          realm.status == "blocked" ->
            # TTL elapsed — auto-expire
            :ok = do_unblock(realm_id, realm.block_count)
            :ok

          true ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Record an auth failure. Transitions realm healthy → blocked (idempotent within
  the same epoch: a second concurrent failure does not extend the TTL).
  """
  @spec block(String.t()) :: :ok
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def block(realm_id) do
    now = System.system_time(:second)

    {:ok, _} =
      State.transaction(fn conn ->
        realm = fetch_realm(conn, realm_id)

        if realm && realm.status == "blocked" do
          # Already blocked in this epoch — idempotent.
          :ok
        else
          block_count = (realm && realm.block_count) || 0
          new_count = block_count + 1
          backoff = Enum.at(@block_backoff_sec, min(block_count, length(@block_backoff_sec) - 1))
          blocked_until = now + backoff
          epoch = ((realm && realm.epoch) || 0) + 1

          Logger.warning("[auth_realms] blocking realm=#{realm_id} epoch=#{epoch} block_count=#{new_count} blocked_until=#{blocked_until} (#{div(backoff, 60)}m)")

          upsert_realm!(conn, %{
            realm_id: realm_id,
            status: "blocked",
            epoch: epoch,
            blocked_until: blocked_until,
            block_count: new_count,
            throttled_until: realm && realm.throttled_until,
            throttle_count: (realm && realm.throttle_count) || 0,
            updated_at: now
          })
        end
      end)

    :ok
  end

  @doc """
  Record a rate-limit event. Sets `throttled_until`; does not affect auth status.
  `retry_at` is a unix timestamp in seconds.
  """
  @spec throttle(String.t(), integer()) :: :ok
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def throttle(realm_id, retry_at) when is_integer(retry_at) do
    now = System.system_time(:second)

    {:ok, _} =
      State.transaction(fn conn ->
        realm = fetch_realm(conn, realm_id)
        prev_until = (realm && realm.throttled_until) || 0
        new_until = max(prev_until, retry_at)
        count = ((realm && realm.throttle_count) || 0) + 1

        Logger.warning("[auth_realms] throttling realm=#{realm_id} throttled_until=#{new_until} throttle_count=#{count}")

        upsert_realm!(conn, %{
          realm_id: realm_id,
          status: (realm && realm.status) || "healthy",
          epoch: (realm && realm.epoch) || 0,
          blocked_until: realm && realm.blocked_until,
          block_count: (realm && realm.block_count) || 0,
          throttled_until: new_until,
          throttle_count: count,
          updated_at: now
        })
      end)

    :ok
  end

  @doc "Manual immediate recovery — resets realm to healthy and clears block_count."
  @spec unblock(String.t()) :: :ok
  def unblock(realm_id) do
    :ok = do_unblock(realm_id, 0)
    Logger.info("[auth_realms] manually unblocked realm=#{realm_id}")
    :ok
  end

  @doc "Check all blocked realms and auto-expire those past their TTL."
  @spec expire_stale() :: :ok
  def expire_stale do
    now = System.system_time(:second)

    {:ok, expired} =
      State.transaction(fn conn ->
        sql = "SELECT realm_id, block_count FROM auth_realms WHERE status = 'blocked' AND blocked_until <= ?"
        {:ok, stmt} = Sqlite3.prepare(conn, sql)
        :ok = Sqlite3.bind(stmt, [now])
        rows = collect_rows(conn, stmt, [])
        :ok = Sqlite3.release(conn, stmt)
        Enum.map(rows, fn [rid, bc] -> {rid, bc} end)
      end)

    Enum.each(expired, fn {realm_id, block_count} ->
      :ok = do_unblock(realm_id, block_count)
      Logger.info("[auth_realms] TTL expired, unblocked realm=#{realm_id}")
    end)

    :ok
  end

  ## Internals

  defp do_unblock(realm_id, _prev_block_count) do
    now = System.system_time(:second)

    {:ok, _} =
      State.transaction(fn conn ->
        realm = fetch_realm(conn, realm_id)

        upsert_realm!(conn, %{
          realm_id: realm_id,
          status: "healthy",
          epoch: (realm && realm.epoch) || 0,
          blocked_until: nil,
          block_count: (realm && realm.block_count) || 0,
          throttled_until: realm && realm.throttled_until,
          throttle_count: (realm && realm.throttle_count) || 0,
          updated_at: now
        })
      end)

    :ok
  end

  defp fetch_realm(conn, realm_id) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "SELECT realm_id, status, epoch, blocked_until, block_count, throttled_until, throttle_count, updated_at FROM auth_realms WHERE realm_id = ?"
      )

    :ok = Sqlite3.bind(stmt, [realm_id])
    result = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    case result do
      {:row, [rid, status, epoch, blocked_until, block_count, throttled_until, throttle_count, updated_at]} ->
        %{
          realm_id: rid,
          status: status,
          epoch: epoch,
          blocked_until: blocked_until,
          block_count: block_count,
          throttled_until: throttled_until,
          throttle_count: throttle_count,
          updated_at: updated_at
        }

      :done ->
        nil
    end
  end

  defp upsert_realm!(conn, m) do
    exec!(
      conn,
      """
      INSERT INTO auth_realms(realm_id, status, epoch, blocked_until, block_count, throttled_until, throttle_count, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(realm_id) DO UPDATE SET
        status          = excluded.status,
        epoch           = excluded.epoch,
        blocked_until   = excluded.blocked_until,
        block_count     = excluded.block_count,
        throttled_until = excluded.throttled_until,
        throttle_count  = excluded.throttle_count,
        updated_at      = excluded.updated_at
      """,
      [
        m.realm_id,
        m.status,
        m.epoch,
        m.blocked_until,
        m.block_count,
        m.throttled_until,
        m.throttle_count,
        m.updated_at
      ]
    )
  end

  defp exec!(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end

  defp collect_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
