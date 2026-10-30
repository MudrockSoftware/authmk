# Migrating from Pow

The path is the one in [Migrating from phx.gen.auth](migrating-from-phx-gen-auth.md),
with Pow's names and Pow's password hashes. User IDs stay the same; users
sign in once more, since Pow's sessions live in its cache, not the
database.

## Configure

Pow's IDs are integers by default:

```elixir
use Authmk,
  primary_key: :id,
  password_hasher: MyApp.PowPasswords,
  plugins: [Authmk.Plugins.EmailPassword]
```

## Passwords

Pow hashes with PBKDF2 (`$pbkdf2-sha512$...`). authmk hashes new passwords
with Argon2id; a hasher of your own verifies both, so existing passwords
keep working:

```elixir
defmodule MyApp.PowPasswords do
  @behaviour Authmk.Password

  @impl true
  def hash(password), do: Authmk.Password.Argon2.hash(password)

  @impl true
  def verify(password, "$pbkdf2-" <> _ = hash),
    do: Pow.Ecto.Schema.Password.pbkdf2_verify(password, hash)

  def verify(password, hash), do: Authmk.Password.Argon2.verify(password, hash)

  @impl true
  def no_user_verify, do: Authmk.Password.Argon2.no_user_verify()
end
```

Keep `:pow` as a dependency for this module: old hashes stay PBKDF2 until
their users change their passwords (authmk doesn't rehash at sign-in).

## Tables

Follow steps 2 to 4 of the phx.gen.auth guide, with Pow's columns:

* the password hash is in `password_hash` (not `hashed_password`);
* with `PowEmailConfirmation`, verified users have `email_confirmed_at`
  (not `confirmed_at`);
* `PowAssent` identities (`user_identities`: `provider`, `uid`) become
  authmk accounts: `provider_id` and `account_id`, without tokens. Users
  sign in with the provider again and authmk links them by that account.

## Switch over

| Pow | authmk |
|---|---|
| `Pow.Plug.Session` in the endpoint | `plug Authmk.Plug.FetchSession, auth: MyApp.Auth` in the browser pipeline |
| `Pow.Plug.RequireAuthenticated` | `Authmk.Plug.RequireUser` |
| `Pow.Plug.RequireNotAuthenticated` | `authmk_live_session ..., require: :signed_out` |
| `Pow.Plug.current_user(conn)` | `Authmk.Phoenix.Controller.current_user(conn)` |
| `pow_routes()` | `authmk_routes "/auth", MyApp.Auth` and your pages with `Authmk.Components` |
| `PowResetPassword` | `forgot_password_form/1`, `reset_password_form/1` |
| `PowPersistentSession` | sessions are persistent by default (`remember_me`) |

Then drop `password_hash` and Pow's other columns once nothing reads them.
