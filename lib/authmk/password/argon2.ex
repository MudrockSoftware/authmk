defmodule Authmk.Password.Argon2 do
  @moduledoc """
  Argon2id password hashing via `argon2_elixir`. Cost parameters come from the
  `:argon2_elixir` application config.
  """

  @behaviour Authmk.Password

  @impl true
  def hash(password), do: Argon2.hash_pwd_salt(password)

  @impl true
  def verify(password, hash), do: Argon2.verify_pass(password, hash)

  @impl true
  def no_user_verify, do: Argon2.no_user_verify()
end
