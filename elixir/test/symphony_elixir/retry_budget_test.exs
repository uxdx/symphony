defmodule SymphonyElixir.RetryBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryBudget

  describe "schedule/1" do
    test ":auth_revoked uses 3-step schedule" do
      assert RetryBudget.schedule(:auth_revoked) == [60, 300, 900]
      assert RetryBudget.cap(:auth_revoked) == 3
    end

    test "default reasons use 5-step schedule" do
      for reason <- [:turn_timeout, :sentinel_missing, :rate_limit, :nonce_mismatch, :unknown] do
        assert RetryBudget.schedule(reason) == [60, 300, 900, 3_600, 14_400]
        assert RetryBudget.cap(reason) == 5
      end
    end
  end

  describe "next_at/3 with injected clock and RNG" do
    test "auth_revoked attempts 0..2 produce centred jittered timestamps" do
      now_fn = fn -> 1_000_000 end
      # rand=0.5 → jitter = trunc(base * 0.2 * 0) = 0 (centred)
      rand_fn = fn -> 0.5 end
      opts = [now: now_fn, rand: rand_fn]

      assert {:ok, 1_000_060} = RetryBudget.next_at(0, :auth_revoked, opts)
      assert {:ok, 1_000_300} = RetryBudget.next_at(1, :auth_revoked, opts)
      assert {:ok, 1_000_900} = RetryBudget.next_at(2, :auth_revoked, opts)
    end

    test "auth_revoked exhausts at attempt 3" do
      assert :exhausted = RetryBudget.next_at(3, :auth_revoked, [])
    end

    test "default schedule covers 5 attempts then exhausts" do
      now_fn = fn -> 0 end
      rand_fn = fn -> 0.5 end
      opts = [now: now_fn, rand: rand_fn]

      assert {:ok, 60} = RetryBudget.next_at(0, :turn_timeout, opts)
      assert {:ok, 14_400} = RetryBudget.next_at(4, :turn_timeout, opts)
      assert :exhausted = RetryBudget.next_at(5, :turn_timeout, opts)
    end

    test "jitter bounds ±20% with rand=0.0 and rand=1.0" do
      now_fn = fn -> 0 end
      # rand=0.0 → jitter = trunc(60 * 0.2 * -1) = -12 → 60 + (-12) = 48
      assert {:ok, 48} = RetryBudget.next_at(0, :turn_timeout, now: now_fn, rand: fn -> 0.0 end)
      # rand=1.0 → jitter = trunc(60 * 0.2 * 1) = 12 → 60 + 12 = 72
      assert {:ok, 72} = RetryBudget.next_at(0, :turn_timeout, now: now_fn, rand: fn -> 1.0 end)
    end
  end
end
