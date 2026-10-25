if Code.ensure_loaded?(Bcrypt) do
  defmodule Authmk.Password.Bcrypt do
    @moduledoc """
    Bcrypt password hashing via `bcrypt_elixir` (add it to your deps).

        password_hasher: Authmk.Password.Bcrypt

    Argon2id (the default) is stronger for new apps. Bcrypt is here for
    existing databases, such as those created by `phx.gen.auth`. Cost comes
    from the `:bcrypt_elixir` application config.
    """

    @behaviour Authmk.Password

    @impl true
    def hash(password), do: Bcrypt.hash_pwd_salt(password)

    @impl true
    def verify(password, hash), do: Bcrypt.verify_pass(password, hash)

    @impl true
    def no_user_verify, do: Bcrypt.no_user_verify()
  end
end
