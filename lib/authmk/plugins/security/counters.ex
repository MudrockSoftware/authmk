defmodule Authmk.Plugins.Security.Counters do
  @moduledoc false
  # Counters and flags with an expiry: in secondary storage when there is
  # one (shared by every node), else in this node's ETS table.

  alias Authmk.Storage
  alias Authmk.Storage.ETS

  def increment(%{config: config}, key, ttl) do
    if Storage.configured?(config),
      do: Storage.increment(config, key, ttl),
      else: ETS.increment(table(config), key, ttl)
  end

  def get(%{config: config}, key) do
    if Storage.configured?(config),
      do: Storage.get(config, key),
      else: ETS.get(table(config), key)
  end

  def put(%{config: config}, key, value, ttl) do
    if Storage.configured?(config),
      do: Storage.put(config, key, value, ttl),
      else: ETS.put(table(config), key, value, ttl)
  end

  defp table(config), do: [table: ETS.table(config.auth)]
end
