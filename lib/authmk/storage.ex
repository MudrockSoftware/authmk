defmodule Authmk.Storage do
  @moduledoc """
  Secondary storage: a fast key-value store with expiry, for sessions,
  verification tokens and rate-limit counters.

      secondary_storage: Authmk.Storage.ETS                          # this node only
      secondary_storage: {Authmk.Storage.Redis, conn: MyApp.Redix}   # shared

  With secondary storage configured, sessions and verification tokens live
  there instead of the database (see `session: [store_in_database: true]`
  and `verification: [store_in_database: true]` to keep database copies).

  Implement this behaviour to use another store. Values are strings; `ttl`
  is in seconds, `nil` for no expiry.
  """

  alias Authmk.Config

  @type opts :: keyword()

  @doc "The value at `key`, or `nil`."
  @callback get(opts(), key :: String.t()) :: String.t() | nil

  @doc "Returns the value at `key` and deletes it, atomically."
  @callback get_and_delete(opts(), key :: String.t()) :: String.t() | nil

  @doc "Stores `value` at `key`."
  @callback put(opts(), key :: String.t(), value :: String.t(), ttl :: pos_integer() | nil) :: :ok

  @doc "Deletes `key`."
  @callback delete(opts(), key :: String.t()) :: :ok

  @doc """
  Increments the counter at `key`, creating it with expiry `ttl` when
  missing, atomically. Returns the new count.
  """
  @callback increment(opts(), key :: String.t(), ttl :: pos_integer()) :: pos_integer()

  @doc "Whether secondary storage is configured."
  @spec configured?(Config.t()) :: boolean()
  def configured?(%{secondary_storage: storage}), do: not is_nil(storage)

  @doc false
  @spec get(Config.t(), String.t()) :: String.t() | nil
  def get(config, key), do: call(config, :get, [key])

  @doc false
  @spec get_and_delete(Config.t(), String.t()) :: String.t() | nil
  def get_and_delete(config, key), do: call(config, :get_and_delete, [key])

  @doc false
  @spec put(Config.t(), String.t(), String.t(), pos_integer() | nil) :: :ok
  def put(config, key, value, ttl), do: call(config, :put, [key, value, ttl])

  @doc false
  @spec delete(Config.t(), String.t()) :: :ok
  def delete(config, key), do: call(config, :delete, [key])

  @doc false
  @spec increment(Config.t(), String.t(), pos_integer()) :: pos_integer()
  def increment(config, key, ttl), do: call(config, :increment, [key, ttl])

  defp call(%{secondary_storage: {module, opts}}, function, args),
    do: apply(module, function, [opts | args])
end
