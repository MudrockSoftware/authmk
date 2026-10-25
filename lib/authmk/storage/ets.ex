defmodule Authmk.Storage.ETS do
  @moduledoc """
  In-memory storage in an ETS table, local to one node. Expired entries are
  swept every `:sweep_interval` milliseconds (default one minute).
  """

  @behaviour Authmk.Storage

  use GenServer

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Authmk.Storage
  def increment(server, key, ttl) do
    # Fixed windows: every `ttl` seconds starts a new counter.
    window = div(now(), ttl)
    entry_key = {key, window}
    expires_at = (window + 1) * ttl
    :ets.update_counter(server, entry_key, {2, 1}, {entry_key, 0, expires_at})
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    ^name = :ets.new(name, [:named_table, :public, :set, write_concurrency: true])
    interval = Keyword.get(opts, :sweep_interval, 60_000)
    schedule_sweep(interval)
    {:ok, %{table: name, interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.system_time(:second)
end
