# Migrating from phx.gen.auth

authmk takes over your existing `users` table: user IDs stay the same, so
every table that points at users keeps working, and passwords keep working
because they're moved over as they are (bcrypt). Users sign in once more,
since sessions don't carry over.

This path is tested end to end in authmk's own suite
(`test/authmk/migrating_test.exs`).

## 1. Configure authmk to match

```elixir
defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    # phx.gen.auth's IDs are integers...
    primary_key: :id,
    # ...and its passwords bcrypt (bcrypt_elixir is already in your deps).
    password_hasher: Authmk.Password.Bcrypt,
    plugins: [Authmk.Plugins.EmailPassword]
end
```

Leave the user model's table as `users` (the default).

## 2. Add authmk's columns to `users`

A migration of your own, before authmk's:

```elixir
defmodule MyApp.Repo.Migrations.AddAuthmkUserColumns do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :name, :string
      add :email_verified, :boolean, null: false, default: false
      add :image, :text
    end
  end
end
```

If you add fields to authmk's user model (`additional_fields`) or use
plugins that add user columns (Admin, TwoFactor, Username...), add those
columns here too: compare with the `users` entry in authmk's snapshot after
step 3.

## 3. Generate authmk's tables

```sh
mix authmk.gen.migration --existing users
```

The migration creates authmk's other tables (sessions, accounts,
verifications...) and treats `users` as already there.

## 4. Move the data

```elixir
defmodule MyApp.Repo.Migrations.MoveUsersToAuthmk do
  use Ecto.Migration
  import Ecto.Query

  def up do
    execute(fn ->
      # authmk requires a name.
      repo().update_all(from(u in "users", where: is_nil(u.name), update: [set: [name: u.email]]), [])

      # Typed, so every database stores a boolean.
      repo().update_all(
        from(u in "users",
          where: not is_nil(u.confirmed_at),
          update: [set: [email_verified: type(^true, :boolean)]]
        ),
        []
      )

      # Passwords live on a "credential" account in authmk.
      now = DateTime.utc_now()

      accounts =
        from(u in "users", where: not is_nil(u.hashed_password), select: %{id: u.id, hash: u.hashed_password})
        |> repo().all()
        |> Enum.map(fn user ->
          %{
            user_id: user.id,
            account_id: to_string(user.id),
            provider_id: "credential",
            password: user.hash,
            inserted_at: now,
            updated_at: now
          }
        end)

      repo().insert_all("accounts", accounts)
    end)
  end

  def down, do: :ok
end
```

Run `mix ecto.migrate`.

## 5. Switch the app over

| phx.gen.auth | authmk |
|---|---|
| `fetch_current_scope_for_user` plug | `plug Authmk.Plug.FetchSession, auth: MyApp.Auth` |
| `require_authenticated_user` | `plug Authmk.Plug.RequireUser, redirect_to: "/sign-in"` |
| `redirect_if_user_is_authenticated` | `authmk_live_session ..., require: :signed_out` |
| `UserAuth` `on_mount` hooks | `authmk_live_session ..., require: :user` |
| `@current_scope.user` | `@current_user` |
| `UserSessionController`, login and settings LiveViews | `Authmk.Components`, `Authmk.Components.Account` |
| `Accounts.get_user_by_email/1` | `Authmk.Testing.get_user_by/2` in tests; your own queries in the app |
| `UserNotifier` | the auth module's `send_*` callbacks, or `Authmk.Emails` |
| magic links | `Authmk.Plugins.MagicLink` |

See [Phoenix and LiveView](phoenix-and-liveview.md).

## 6. Clean up

Once it runs in production: drop `users_tokens`, and the `hashed_password`
and `confirmed_at` columns, in a migration of your own; delete `UserAuth`,
`UserToken` and the generated controllers and LiveViews.

Emails stay as they are. On PostgreSQL, a `citext` email column keeps
working: authmk lowercases emails itself.
