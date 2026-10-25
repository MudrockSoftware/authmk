defmodule Authmk.Storage.ETS do
  @moduledoc """
  Secondary storage in an ETS table, local to one node. Each auth module
  starts its own table; expired entries are swept every minute.

  Use it for a single node, or for development. With several nodes, use a
  shared store such as `Authmk.Storage.Redis`, or sessions and rate limits
  won't be shared between them.
  """

  @behaviour Authmk.Storage

  use GenServer

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :table))
  end

  @impl Authmk.Storage
  def get(opts, key) do
    now = now()

    case :ets.lookup(opts[:table], key) do
      [{^key, value, expires_at}] when expires_at > now -> value
      _missing_or_expired -> nil
    end
  end

  @impl Authmk.Storage
  def get_and_delete(opts, key) do
    now = now()

    case :ets.take(opts[:table], key) do
      [{^key, value, expires_at}] when expires_at > now -> value
      _missing_or_expired -> nil
    end
  end

  @impl Authmk.Storage
  def put(opts, key, value, ttl) do
    expires_at = if ttl, do: now() + ttl, else: :infinity
    true = :ets.insert(opts[:table], {key, value, expires_at})
    :ok
  end

  @impl Authmk.Storage
  def delete(opts, key) do
    true = :ets.delete(opts[:table], key)
    :ok
  end

  # Callers put the window in the key, so a key is never reused after it
  # expires and the default below always starts a fresh counter.
  @impl Authmk.Storage
  def increment(opts, key, ttl) do
    :ets.update_counter(opts[:table], key, {2, 1}, {key, 0, now() + ttl})
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.fetch!(opts, :table)

    ^table =
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    interval = Keyword.get(opts, :sweep_interval, 60_000)
    schedule_sweep(interval)
    {:ok, %{table: table, interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # Integers sort before atoms, so `:infinity` entries are never swept.
    _count = :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.system_time(:second)
end
