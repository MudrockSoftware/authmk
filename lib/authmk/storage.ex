defmodule Authmk.Storage do
  @moduledoc """
  Behaviour for fast key-value storage with expiry, used for rate limits.
  `Authmk.Storage.ETS` is the built-in implementation.
  """

  @doc """
  Increments the counter at `key`, creating it with expiry `ttl` (seconds)
  when missing. Returns the new count.
  """
  @callback increment(server :: atom(), key :: term(), ttl :: pos_integer()) :: pos_integer()
end
