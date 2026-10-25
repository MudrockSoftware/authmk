defmodule Authmk.Token do
  @moduledoc """
  Random tokens and their hashes.

  Tokens are 256-bit random values, URL-safe Base64 encoded. The database only
  stores their SHA-256 hash, so a database leak doesn't expose usable tokens.
  """

  @doc "A new random token."
  @spec generate(pos_integer()) :: String.t()
  def generate(bytes \\ 32),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "SHA-256 hash of a token, hex encoded."
  @spec hash(String.t()) :: String.t()
  def hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
end
