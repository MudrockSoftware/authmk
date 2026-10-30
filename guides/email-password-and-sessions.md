# Email, password and sessions

`Authmk.Plugins.EmailPassword` lets users sign up and sign in with an email
and a password. Every sign-in method ends in a session: a random token in an
`HttpOnly` cookie, stored hashed on the server.

## Setup

```elixir
defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    plugins: [{Authmk.Plugins.EmailPassword, require_email_verification: true}]

  @impl Authmk
  def send_verification_email(%{user: user, url: url}, _ctx),
    do: MyApp.Mailer.deliver_verification(user.email, url)

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx),
    do: MyApp.Mailer.deliver_reset(user.email, url)
end
```

authmk calls these with the `user`, the `url` to send and the raw `token`,
in the background (see `background:`). Without them, it logs a warning.

The plugin takes `require_email_verification` (default `false`),
`auto_sign_in` after sign-up (`true`), `disable_sign_up` (`false`),
`min_password_length` and `max_password_length` (8 and 128),
`reset_password_token_expires_in` (3600 seconds),
`revoke_sessions_on_password_reset` (`true`) and `reset_password_page`
(see Password reset).

## Signing up and signing in

```http
POST /auth/sign-up/email
{"email": "ada@example.com", "password": "correct horse", "name": "Ada"}

200 {"user": {"id": "...", "email": "ada@example.com", "name": "Ada", "email_verified": false, ...}}
```

Emails are trimmed and lowercased. `name` is required by the user model.
Other user fields with `input: true` are accepted; the rest, like
`email_verified`, are ignored. With `auto_sign_in`, the response also sets
the session cookie. With `require_email_verification`, it answers
`{"status": true}` and signs no one in.

```http
POST /auth/sign-in/email
{"email": "ada@example.com", "password": "correct horse", "remember_me": false}

200 {"user": {...}, "redirect": null}
```

Both take `callback_url` (a relative path or a trusted origin; sign-in
echoes it as `redirect`) and `remember_me` (default `true`). Without
remember me, the cookie lasts until the browser closes. When a plugin needs
another step, like a second factor, the answer is that plugin's challenge.

Failures don't reveal which emails are registered. A wrong password and an
unknown email both answer `401 invalid_credentials`, in the same time. With
`require_email_verification`, a taken email signs up like a new one, and
`on_existing_user_sign_up/2` can tell the real owner. Without it, sign-up
answers `422 user_already_exists`.

Errors are `{"error": {"code": ..., "message": ..., "details": {...}}}`,
with missing fields in `details.fields`. Each client gets 3 requests per 10
seconds; change it with `rate_limit: [rules: %{"/sign-in/email" => [max: 5]}]`.

## Passwords

New passwords are checked for length: `password_too_short` or
`password_too_long`. Add `Authmk.Plugins.HaveIBeenPwned` to refuse breached
ones.

Passwords are hashed with Argon2id (`Authmk.Password.Argon2`). Its cost
comes from the `:argon2_elixir` config. Lower it in tests only:

```elixir
# config/test.exs
config :argon2_elixir, t_cost: 1, m_cost: 8
```

For a database that already holds Bcrypt hashes, like one made by
`phx.gen.auth`, add `{:bcrypt_elixir, "~> 3.2"}` to your deps and set
`password_hasher: Authmk.Password.Bcrypt`. Bcrypt only uses a password's
first 72 bytes, so new passwords longer than that fail with
`password_too_long` instead of being cut short; passwords set before keep
working. Any module that implements `Authmk.Password` (`hash/1`,
`verify/2`, `no_user_verify/0`, and optionally `max_bytes/0`) works too.

`Authmk.Plugins.EmailPassword.set_password(MyApp.Auth, user, password)` gives
one to a user who signed up another way, or fails with `password_already_set`.

## Email verification

A link is sent on sign-up with `require_email_verification`, or with
`email_verification: [send_on_sign_up: true]`. Under `email_verification:`,
`send_on_sign_in: true` sends a new one when an unverified user tries to
sign in (they get `403 email_not_verified`),
`auto_sign_in_after_verification: true` signs them in when they open it,
and `expires_in` sets its lifetime (3600 seconds).

The link points to `GET /auth/verify-email?token=...&callback_url=...`.
It marks the email verified and redirects to `callback_url`, or answers
`{"status": true, "user": {...}}` without one. A bad or expired token
redirects to `callback_url?error=invalid_token`. Each link works once.

`POST /auth/send-verification-email` with `email` (and `callback_url`) sends
a new link. It answers `{"status": true}` for unknown and verified emails
too. A signed-in user can leave out `email`. `before_email_verification/2` and
`after_email_verification/2` run around each verification.

## Password reset

```http
POST /auth/request-password-reset
{"email": "ada@example.com", "redirect_to": "/reset-password"}

200 {"status": true}
```

The answer is always the same, and unknown emails get no email. A known user
gets a link to `GET /auth/reset-password/<token>`, which redirects to
`/reset-password?token=...` (or `?error=invalid_token`). Without
`redirect_to`, the link goes to the plugin's `reset_password_page`
(`reset_password_page: "/reset-password"`); without either, it ends on
authmk's error page, and requesting it logs a warning. Your page then
sends the new password:

```http
POST /auth/reset-password
{"token": "...", "new_password": "a new password"}

200 {"status": true}
```

The token works once. Every session of the user ends, since whoever knew the
old password may still be signed in, then `on_password_reset/2` runs. Set
`revoke_sessions_on_password_reset: false` to keep them. Resets by email or
SMS code do the same.

## Changing the password

`POST /auth/change-password` takes `current_password`, `new_password` and
`revoke_other_sessions` (default `false`), which signs every other device
out. It answers `{"user": {...}}`, or `401 invalid_password`.
`POST /auth/verify-password` with `{"password": "..."}` only checks it, for
pages that ask again before a sensitive step.

## Changing the email

Turn it on with `user: [change_email: [enabled: true]]`, then
`POST /auth/change-email` with `new_email` (and `callback_url`). It answers
`{"status": true}`, also for an address another account has, so this can't
reveal who has an account; then nothing changes and nothing is sent. A link
only works while the user still has the address it was sent from: changing
the email again makes older links useless.

The email doesn't change yet: `send_change_email_verification/2` mails a
link to the new address, and opening it moves the user there, verified.
For a verified email with `confirm_current_email: true`,
`send_change_email_confirmation/2` first mails the current address; its
link (`GET /auth/change-email/confirm`) then sends the one for the new
address. An unverified email waits for the link too, so no account holds
an address nobody proved.

## Deleting the account

Turn it on with `user: [delete_user: [enabled: true]]`. Then
`POST /auth/delete-user` with `{"password": "..."}`, or with no password
from a fresh session (see below), answers `{"success": true}`. The user,
their sessions and accounts are deleted, and the cookies cleared.

With `verify_with_email: true`, `send_delete_account_verification/2` mails
a link to `GET /auth/delete-user/callback` instead. It deletes only when
opened by the same signed-in user, within `expires_in` (one day).

## Sessions

Set these under `session:`. A session lasts `expires_in` seconds (7 days)
from its last refresh. A request refreshes it, and its cookie, once
`update_age` (1 day) has passed; `disable_refresh: true` keeps the first
expiry. With `defer_refresh: true`, `GET /auth/get-session` stays read-only
and adds `"needs_refresh": true`, and `POST /auth/get-session` refreshes.

A session is fresh for `fresh_age` seconds (1 day) after sign-in;
refreshing doesn't count. Sensitive actions, like deleting an account
without a password, need a fresh one, or answer `403 session_not_fresh`.
`fresh_age: 0` turns the check off.

| Method | Path | Does |
|---|---|---|
| GET | `/get-session` | `{"session": {...}, "user": {...}}`, or `null` |
| POST | `/sign-out` | ends this session |
| GET | `/list-sessions` | the user's active sessions, without tokens |
| POST | `/revoke-session` | ends one, by `id` |
| POST | `/revoke-other-sessions` | ends all but this one |
| POST | `/revoke-sessions` | ends all, this one too |

Users can only revoke their own sessions. `customize_session/2` shapes the
`get-session` answer. From your own code, `Authmk.Sessions` takes a context:

```elixir
ctx = Authmk.Context.new(MyApp.Auth.config())
Authmk.Sessions.list(ctx, user.id)
Authmk.Sessions.revoke_all(ctx, user.id)
```

Sessions live in the database, or in secondary storage when you set one;
see `Authmk.SessionStore`, stateless sessions included.

## The cookie cache

The cookie cache keeps a copy of the session and user in a second,
short-lived cookie, so reading the session needs no database query:

```elixir
session: [cookie_cache: [enabled: true, max_age: 300, strategy: :signed]]
```

`:signed` can be read by the browser but not changed, `:encrypted` can't be
read either, and `:jwt` and `:jwt_jwks` make it a JWT. Only
`GET /auth/get-session` and `Authmk.Plug.FetchSession` read it; everything
that changes data checks the store.

The trade-off: a revoked session can still read its cached data for up to
`max_age`. Send `disable_cookie_cache=true` to `get-session` for a fresh
read, or change `version` to drop every cache (`Authmk.CookieCache`).

## Several accounts on one device

`Authmk.Plugins.MultiSession` keeps each sign-in on the device, so users
switch accounts without signing out:

```elixir
plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.MultiSession, maximum_sessions: 5}]
```

`GET /auth/multi-session/list-device-sessions` lists them, newest first, as
`[{"session": {...}, "user": {...}}]`. `POST /auth/multi-session/set-active`
and `POST /auth/multi-session/revoke` take a `session_id`, from this
device's sessions only. Past `maximum_sessions`, the oldest is signed out.
`POST /auth/sign-out` signs out every account on the device.

## Reading the session in Plug

```elixir
plug Authmk.Plug.FetchSession, auth: MyApp.Auth
plug Authmk.Plug.RequireUser, redirect_to: "/sign-in"
```

`FetchSession` sets `conn.assigns.current_user`, `current_session` and
`current_principal` (`nil` when signed out), and refreshes the cookie when
due. `RequireUser` turns everyone else away with `401 unauthorized` JSON,
or a redirect. `Authmk.Plug.RequireAuthenticated` and
`Authmk.Plug.RequireRole` cover service accounts and roles.

See also [Phoenix and LiveView](phoenix-and-liveview.md),
[Cookies across domains](cookies-and-domains.md) and
[SPAs, desktop and mobile apps](api-clients.md) for bearer tokens.
