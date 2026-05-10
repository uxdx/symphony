defmodule SymphonyElixir.RetryBudget do
  @moduledoc """
  PR3 retry scheduling. Reason-specific budgets:

    * `:auth_revoked` — 3-step (60 / 300 / 900) → quarantined.
      (Lower cap. PR4 promotes this to `auth_blocked` realm pause.)
    * default (`:turn_timeout`, `:sentinel_missing`, `:rate_limit`,
      `:nonce_mismatch`, `:unknown`) — 5-step (60 / 300 / 900 / 3600 / 14400).

  Both schedules add ±20% jitter. Clock and RNG are injectable so unit tests
  can pin deterministic timing.
  """

  @schedule_default [60, 300, 900, 3_600, 14_400]
  @schedule_auth   [60, 300, 900]

  @type reason :: atom()
  @type opts :: [
          now: (-> non_neg_integer()),
          rand: (-> float())
        ]

  @doc "Per-reason schedule (seconds, no jitter)."
  @spec schedule(reason()) :: [pos_integer()]
  def schedule(:auth_revoked), do: @schedule_auth
  def schedule(_), do: @schedule_default

  @doc "Cap for a reason — number of attempts before `quarantined`."
  @spec cap(reason()) :: pos_integer()
  def cap(reason), do: length(schedule(reason))

  @doc """
  Compute next attempt timestamp given prior `used` count and reason.

  Returns `:exhausted` when `used + 1` exceeds the schedule for this reason.
  Otherwise `{:ok, next_ts}` where `next_ts = now + schedule[used] + jitter`.
  """
  @spec next_at(non_neg_integer(), reason(), opts()) :: {:ok, pos_integer()} | :exhausted
  def next_at(used, reason, opts \\ []) when is_integer(used) and used >= 0 do
    sched = schedule(reason)

    if used >= length(sched) do
      :exhausted
    else
      base = Enum.at(sched, used)
      now = (Keyword.get(opts, :now) || (&default_now/0)).()
      rand = (Keyword.get(opts, :rand) || (&default_rand/0)).()
      jitter = trunc(base * 0.2 * (rand * 2 - 1))
      {:ok, now + base + jitter}
    end
  end

  defp default_now, do: System.system_time(:second)
  defp default_rand, do: :rand.uniform()
end
