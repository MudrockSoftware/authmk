if Code.ensure_loaded?(Redix) do
  defmodule Authmk.Storage.Redis do
    @moduledoc """
    Secondary storage in Redis (or Valkey) 7+, through a `Redix` connection
    you start yourself:

        children = [{Redix, {System.fetch_env!("REDIS_URL"), [name: MyApp.Redix]}}, ...]

        secondary_storage: {Authmk.Storage.Redis, conn: MyApp.Redix}

    ## Options

      * `:conn` - the Redix connection name (required)
      * `:prefix` - key prefix, default `"authmk:"`
    """

    @behaviour Authmk.Storage

    @impl true
    def get(opts, key), do: command!(opts, ["GET", key(opts, key)])

    @impl true
    def get_and_delete(opts, key), do: command!(opts, ["GETDEL", key(opts, key)])

    @impl true
    def put(opts, key, value, nil) do
      "OK" = command!(opts, ["SET", key(opts, key), value])
      :ok
    end

    def put(opts, key, value, ttl) do
      "OK" = command!(opts, ["SET", key(opts, key), value, "EX", Integer.to_string(ttl)])
      :ok
    end

    @impl true
    def delete(opts, key) do
      _count = command!(opts, ["DEL", key(opts, key)])
      :ok
    end

    # EXPIRE ... NX sets the expiry only when the counter is new.
    @impl true
    def increment(opts, key, ttl) do
      key = key(opts, key)

      {:ok, [count, _set]} =
        Redix.transaction_pipeline(conn(opts), [
          ["INCR", key],
          ["EXPIRE", key, Integer.to_string(ttl), "NX"]
        ])

      count
    end

    defp command!(opts, command), do: Redix.command!(conn(opts), command)

    defp conn(opts), do: Keyword.fetch!(opts, :conn)

    defp key(opts, key), do: Keyword.get(opts, :prefix, "authmk:") <> key
  end
end
