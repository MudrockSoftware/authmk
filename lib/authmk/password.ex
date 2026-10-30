defmodule Authmk.Password do
  @moduledoc """
  Behaviour for password hashers. The default is `Authmk.Password.Argon2`
  (Argon2id). Set `password_hasher:` in config to use another one.
  """

  @doc "Hashes a password."
  @callback hash(password :: String.t()) :: String.t()

  @doc "Checks a password against a hash."
  @callback verify(password :: String.t(), hash :: String.t()) :: boolean()

  @doc """
  Spends the same time as `verify/2` and returns `false`. Called when there is
  no user, so response times don't reveal which emails are registered.
  """
  @callback no_user_verify() :: false

  @doc """
  The longest password, in bytes, that `hash/1` uses in full. Bcrypt
  ignores everything after 72 bytes, so two passwords that start the same
  would both work; longer new passwords are refused with
  `password_too_long` instead. Leave it out when every byte counts.
  """
  @callback max_bytes() :: pos_integer()

  @optional_callbacks max_bytes: 0
end
