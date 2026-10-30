# Migrating from Ash Authentication

The path is the one in [Migrating from phx.gen.auth](migrating-from-phx-gen-auth.md),
with Ash's names. authmk takes over the `users` table that your `User`
resource uses; user IDs and passwords (bcrypt) stay. Users sign in once
more, since Ash's tokens don't carry over.

## Configure

Ash's users have UUID primary keys, like authmk's default:

```elixir
use Authmk,
  password_hasher: Authmk.Password.Bcrypt,
  plugins: [Authmk.Plugins.EmailPassword]
```

Add `{:bcrypt_elixir, "~> 3.2"}` if it isn't there already.

## Tables

Follow steps 2 to 4 of the phx.gen.auth guide, with these differences:

* Ash's `users` table may have no timestamps. Add `inserted_at` and
  `updated_at` in step 2 (nullable), and set them in step 4:
  `update: [set: [inserted_at: type(^now, :utc_datetime_usec), updated_at: type(^now, :utc_datetime_usec)]]`.
* The password hash is in `hashed_password`, as with phx.gen.auth.
* With confirmation, verified users have `confirmed_at`.
* `tokens` (Ash's sign-in tokens) can be dropped once you've switched.

## Your `User` resource

The `users` table is authmk's now: create and change users through authmk.
Your Ash `User` resource can keep reading the table (for relationships and
policies) if you add authmk's new attributes and remove the
`AshAuthentication` extension, its strategies and its `hashed_password`
attribute. Actors in Ash policies come from `@current_user` (see
`Authmk.Plug.FetchSession`):

```elixir
Ash.read!(MyApp.Posts.Post, actor: conn.assigns.current_user)
```

## Switch over

| Ash Authentication | authmk |
|---|---|
| `AshAuthentication.Plug` router (`sign_in_route`, `auth_routes`) | `authmk_routes "/auth", MyApp.Auth` and `Authmk.Components` |
| `load_from_session` | `plug Authmk.Plug.FetchSession, auth: MyApp.Auth` |
| `ash_authentication_live_session` | `authmk_live_session` |
| `AshAuthentication.Phoenix.LiveSession` `on_mount` | `Authmk.LiveView` |
| OAuth2 strategies | `social_providers:` |
| magic link strategy | `Authmk.Plugins.MagicLink` |
| API key strategy | `Authmk.Plugins.APIKey` |
