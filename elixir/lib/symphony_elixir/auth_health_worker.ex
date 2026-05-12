defmodule SymphonyElixir.AuthHealthWorker do
  @moduledoc """
  PR4 background worker. Ticks every 60 s and expires auth_realms rows whose
  `blocked_until` TTL has elapsed, transitioning them back to healthy so that
  the next `begin_turn` admission check succeeds.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.State.AuthRealms

  @tick_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    AuthRealms.expire_stale()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
