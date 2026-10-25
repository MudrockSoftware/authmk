defmodule Authmk.Email do
  @moduledoc """
  Email address normalization and validation.

  Emails are trimmed and lowercased with `String.downcase/1` in its default
  mode. Never use locale-aware casing here: Turkish casing would turn
  `INFO@x.com` into `ınfo@x.com`.
  """

  @max_length 254

  @doc "Trims and lowercases an email address."
  @spec normalize(String.t()) :: String.t()
  def normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()

  @doc "Basic structural check: one `@`, a dot in the domain, no whitespace."
  @spec valid?(String.t()) :: boolean()
  def valid?(email) when is_binary(email) do
    byte_size(email) <= @max_length and
      Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email)
  end
end
