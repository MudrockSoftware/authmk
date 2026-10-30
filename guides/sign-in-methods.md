# Sign-in methods

Each method below is a plugin: add it, run `mix authmk.gen.migration` and
`mix ecto.migrate`, and call its endpoints under `/auth` (the default
`base_path`). Its module docs list every option. For OAuth providers, see
[Social sign-in](social-sign-in.md). Sign-ins go through two-factor
authentication when it's on, except where noted. Send callbacks get
the message and an `Authmk.Context`, in the background: `ctx.conn` may be
`nil`. Errors are `{"error": {"code": "...", "message": "..."}}`.

## Two-factor authentication

A second step after the first: a code from an authenticator app (TOTP), a
one-time code by email or SMS, or a backup code.

```elixir
use Authmk,
  plugins: [
    Authmk.Plugins.EmailPassword,
    {Authmk.Plugins.TwoFactor, issuer: "My App", send_otp: &MyApp.Auth.send_two_factor_code/2}
  ]
```

`send_otp` gets `%{user: user, otp: code}`; without it, codes are off.

A signed-in user calls `POST /auth/two-factor/enable` with their
`password`, and gets `totp_uri` (show it as a QR code) and `backup_codes`
(show them once). 2FA is on once they send a first code to
`POST /auth/two-factor/verify-totp` (`{"code": "123456"}`), or to
`/two-factor/verify-otp` after `/two-factor/send-otp`. `/two-factor/disable`,
`/two-factor/get-totp-uri`, `/two-factor/generate-backup-codes` and
`/two-factor/view-backup-codes` take the `password` too. With
`allow_passwordless: true`, users without one use a fresh session instead.

Then a sign-in answers with a challenge, and sets a `two_factor` cookie:

```http
POST /auth/sign-in/email  {"email": "ada@example.com", "password": "..."}
→ {"two_factor_redirect": true, "two_factor_methods": ["totp", "otp", "backup_code"]}
```

The client sends a `code` to `/two-factor/verify-totp`,
`/two-factor/verify-otp` (after `/two-factor/send-otp`) or
`/two-factor/verify-backup-code`. The right one answers `{"user": {...}}`
and sets the session; with `"trust_device": true`, this browser skips 2FA
for `trust_device_days` (30). Social sign-in and magic links end in a
redirect: set `two_factor_page: "/two-factor"` to send users to your page.

Security notes: secrets and codes are stored encrypted. An authenticator
code works once and a backup code is used up, even under concurrent
requests. After `max_attempts` (5) wrong codes, or 10 minutes, the user
signs in again. Turning 2FA off, or on again, ends every trusted device.
SMS is the weakest second factor: offer TOTP or passkeys first.

## Passkeys

Face ID, Touch ID, password managers, security keys: nothing to phish.

```elixir
# mix.exs
{:wax_, "~> 0.7"}

use Authmk, plugins: [{Authmk.Plugins.Passkey, origin: "https://app.example.com"}]
```

`origin` defaults to the base URL's, and `rp_id` (the domain passkeys
belong to) to its host. Each ceremony takes two calls. The first answers
with WebAuthn's JSON options, for
`PublicKeyCredential.parseCreationOptionsFromJSON()` or
`parseRequestOptionsFromJSON()`. The second takes `credential.toJSON()`
as `response`:

```http
POST /auth/passkey/generate-register-options
POST /auth/passkey/verify-registration  {"response": {...}, "name": "Work laptop"}
→ {"passkey": {...}}
POST /auth/passkey/generate-authenticate-options
POST /auth/passkey/verify-authentication  {"response": {...}}
→ {"user": {...}}
```

Registering needs a signed-in user, unless `sign_up: true`: then visitors
send `email` and `name` (and optionally `callback_url`) to
`generate-register-options`, and the account is created with the passkey.
Until its owner proves the email, the account has a placeholder
(`passkey-<random>@<rp_id>`): the email gets a link through
`send_change_email_verification/2`, and opening it moves the account there,
verified. Sign-in options without a session list no
credentials, so the browser offers every passkey for the site, autofill
included. `GET /auth/passkey/list-user-passkeys`,
`POST /auth/passkey/update-passkey` (`id`, `name`) and
`POST /auth/passkey/delete-passkey` (`id`) manage them.

Security notes: a response made for another origin or `rp_id` is refused.
Each challenge works once, from the browser that asked for it. A passkey
whose counter goes backwards is refused (`passkey_cloned`). A passkey that
verified the user (PIN, biometrics) counts as two factors and skips 2FA;
one that didn't goes through 2FA like a password. Set
`user_verification: "required"` to always ask. With `sign_up`, a passkey
registered with someone else's email never holds their address, so it
can't keep them from signing up, or wait in the account they'd reach with
a magic link or a password reset.

In tests, `Authmk.Testing.FakeAuthenticator` plays browser and
authenticator: `register/2` and `authenticate/2` turn options into a
`response` (keep the authenticator `authenticate/2` returns).

## Magic links

A link sent by email, for users who'd forget a password.

```elixir
use Authmk,
  plugins: [{Authmk.Plugins.MagicLink, send_magic_link: &MyApp.Auth.send_magic_link/2}]
```

`send_magic_link` gets `%{email: email, url: url, token: token}`. Options:
`expires_in` (300), `disable_sign_up` and `generate_token`.

```http
POST /auth/sign-in/magic-link  {"email": "ada@example.com", "callback_url": "/dashboard"}
→ {"status": true}
```

The link opens `GET /auth/magic-link/verify`, which signs the user in and
redirects to `callback_url` (`new_user_callback_url` for new users; errors
go to `error_callback_url` as `?error=<code>`). Without a `callback_url`, it
answers with JSON. Unknown emails sign up, unless `disable_sign_up: true`.

Security notes: the answer is the same whether or not the email has an
account. A link works once, expires after `expires_in`, and is stored
hashed. Opening it marks the email verified. Callback URLs must be relative
paths or trusted origins. The link is a `GET`, so a mail scanner that opens
links can use it up first: keep `expires_in` short, and let users ask again.

## Email OTP

Codes by email to sign in, verify an email, reset a password or change an
email. Easier than links on phones.

```elixir
use Authmk,
  plugins: [
    Authmk.Plugins.EmailPassword,
    {Authmk.Plugins.EmailOTP, send_otp: &MyApp.Auth.send_email_code/2}
  ]
```

`send_otp` gets `%{email: email, otp: code, type: type}`, with `type` one of
`:sign_in`, `:email_verification`, `:forget_password` or `:change_email`.

```http
POST /auth/email-otp/send-verification-otp  {"email": "ada@example.com", "type": "sign-in"}
→ {"success": true}
POST /auth/sign-in/email-otp  {"email": "ada@example.com", "otp": "123456"}
→ {"user": {...}}
```

`type` is `"sign-in"`, `"email-verification"` or `"forget-password"`.
Unknown emails sign up, unless `disable_sign_up: true`. The rest:

  * `POST /auth/email-otp/check-verification-otp` (`email`, `type`, `otp`):
    checks a code without using it up
  * `POST /auth/email-otp/verify-email` (`email`, `otp`)
  * `POST /auth/forget-password/email-otp` (`email`), then
    `POST /auth/email-otp/reset-password` (`email`, `otp`, `password`)
  * `POST /auth/email-otp/request-email-change` (`new_email`), then
    `POST /auth/email-otp/change-email` (`new_email`, `otp`), signed in

With `override_default_email_verification: true`, codes replace authmk's
verification links everywhere.

Security notes: sending a code answers the same whether or not the email
has an account. Codes are stored encrypted, expire after `expires_in`
(300), work once for their own type, and stop after `allowed_attempts` (3)
wrong guesses. An email change code only works for the user who asked,
from the address they had then. Asking to change to an address another
account has gets the same answer, but no code. A reset by code ends the
user's other sessions, like a reset by link.

## Phone number

A code by SMS, or a phone number and a password.

```elixir
use Authmk,
  plugins: [
    {Authmk.Plugins.PhoneNumber, send_otp: &MyApp.Auth.send_phone_code/2, sign_up_on_verification: true}
  ]

def send_phone_code(message, ctx), do: Authmk.SMS.send_otp(MyApp.SMS, message, ctx)
```

`send_otp` gets `%{phone_number: number, code: code, purpose: purpose}`
(`:verification` or `:password_reset`). Users get `phone_number` (unique)
and `phone_number_verified`. Numbers must be E.164 (`+14155550123`) unless
you pass a `validator`.

```http
POST /auth/phone-number/send-otp  {"phone_number": "+14155550123"}
POST /auth/phone-number/verify    {"phone_number": "+14155550123", "code": "123456"}
→ {"user": {...}}
```

A code signs in the number's user. An unknown number gets a new user with
`sign_up_on_verification: true` (email `14155550123@phone.invalid`), or a
`phone_number_not_found` error. Add `"update_phone_number": true` to give
the signed-in user the number, or `"disable_session": true` to only verify
it. Also: `POST /auth/sign-in/phone-number` (`phone_number`, `password`),
`POST /auth/phone-number/request-password-reset` then
`POST /auth/phone-number/reset-password` (`phone_number`, `code`,
`new_password`), and `POST /auth/phone-number/remove` (fresh session).

`MyApp.SMS` implements `Authmk.SMS`, one callback wrapping your provider:
`deliver(to, body, opts)`. `Authmk.SMS.send_otp/3` writes the text and
works as TwoFactor's `send_otp` too, sending to the user's `phone_number`.
In tests, `Authmk.SMS.Test` sends `{:sms, to, body}` to the test process.

Security notes: codes are stored encrypted, work once, and stop after
`allowed_attempts` (3) wrong guesses. Wrong passwords and unknown numbers
fail the same way, and reset requests answer the same either way. Clients
can't set `phone_number` directly: only a code does.

Every SMS costs money, and fraudsters ask for codes to premium numbers they
earn from ("SMS pumping"). Besides the per-client rate limit, one number
gets at most `send_limit` codes (`[window: 3600, max: 5]`), however many
clients ask; reset requests count too, before the number is looked up.
Also accept only the countries you serve with `validator`, put a captcha on
`/phone-number/send-otp` (add `:send_phone_number_otp` to the Captcha
plugin's `endpoints`), and set spending limits and geo permissions with
your SMS provider.

## Username

A username and a password, next to the email.

```elixir
use Authmk,
  plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.Username, min_length: 3}]
```

Users get `username` (unique, lowercase by default; letters, numbers, dots
and underscores) and `display_username` (as typed). Clients set them in
`POST /auth/sign-up/email` and `POST /auth/update-user`.

```http
POST /auth/sign-in/username  {"username": "Ada.Lovelace", "password": "..."}
→ {"user": {...}}
```

Wrong usernames and wrong passwords fail the same way. But
`POST /auth/is-username-available` (`username`) answers
`{"available": true}` to anyone: turn it off with
`disable_availability_check: true` if that matters to you.

## Anonymous users

Visitors use the app before they sign up, and keep their data when they do.

```elixir
use Authmk,
  plugins: [
    Authmk.Plugins.EmailPassword,
    {Authmk.Plugins.Anonymous, on_link_account: &MyApp.Carts.move_to_user/2}
  ]
```

`POST /auth/sign-in/anonymous` signs in a new user with `is_anonymous:
true`, an email like `temp-<random>@<your host>` and the name "Anonymous".
When they later sign in or up for real, with any method,
`on_link_account` gets `%{anonymous_user: user, new_user: user}` and the
context: move their data there. The anonymous user is then deleted, unless
`disable_delete_anonymous_user: true`. A failed sign-in links nothing.

## Google One Tap

Google's One Tap prompt, through your `google` social provider: tokens
must be signed by Google for its `client_id`, and users are linked as with
social sign-in.

```elixir
use Authmk,
  social_providers: [google: [client_id: "...", client_secret: "..."]],
  plugins: [{Authmk.Plugins.OneTap, redirect_url: "/dashboard"}]
```

In JavaScript mode, your callback posts Google's credential:

```http
POST /auth/one-tap/callback  {"id_token": "eyJ..."}
→ {"redirect": false, "user": {...}}
```

In redirect mode, set Google's `data-login_uri` to
`<base_url>/auth/one-tap/redirect`. Google posts there from its own origin,
so this endpoint needs Google's double-submit token (the `g_csrf_token`
cookie and field must match) instead of authmk's origin check, and refuses
any `Origin` but `https://accounts.google.com`. It redirects to
`redirect_url`, or to `error_url` with `?error=<code>`.

Turn on `require_nonce: true` so a credential that leaks (from a log, a
proxy, an extension) can't be replayed. Before showing the prompt, get a
nonce and pass it to Google:

```js
const { nonce } = await (await fetch("/auth/one-tap/nonce", { method: "POST" })).json()
google.accounts.id.initialize({ client_id: "...", nonce, callback })
```

Each nonce works once, for `nonce_expires_in` seconds (600). Credentials
without one of authmk's unused nonces fail with `invalid_id_token`. It's
off by default so apps that give Google their own nonces keep working;
new apps should turn it on.

## Sign-In with Ethereum

For web3 apps: wallets sign an EIP-4361 message instead of a password.

```elixir
# mix.exs
{:ex_secp256k1, "~> 0.8"},
{:ex_keccak, "~> 0.7"}

use Authmk, plugins: [{Authmk.Plugins.SIWE, domain: "app.example.com"}]
```

```http
POST /auth/siwe/nonce  {"wallet_address": "0x...", "chain_id": 1}
→ {"nonce": "..."}
POST /auth/siwe/verify  {"message": "...", "signature": "0x...", "wallet_address": "0x...", "chain_id": 1}
→ {"success": true, "user": {...}}
```

The client builds the message with the nonce, and the wallet signs it with
`personal_sign`. `domain` defaults to the base URL's host. New users get a
placeholder email, `<address>@<domain>`. With `anonymous: false`, new
wallets must also send an `email` (and optionally `callback_url`): it gets
a link through `send_change_email_verification/2`, and opening it moves
the account there, verified. Until then no wallet holds the address.

Security notes: the message's address must have signed it and match
`wallet_address`; its domain, chain and nonce must match, and it must be
within its time window. Each nonce works once, for the wallet it was
issued to; asking for another doesn't cancel it, so nobody can keep a
wallet's sign-in failing by asking for nonces. Wallets never join an account by email.
In tests, `Authmk.Testing.FakeWallet` signs messages like a wallet.

## One-time tokens

Hand a signed-in user over to another app, domain or device, with
`Authmk.Plugins.OneTimeToken`.

```http
GET /auth/one-time-token/generate
→ {"token": "..."}
POST /auth/one-time-token/verify  {"token": "..."}
→ {"session": {...}, "user": {...}}
```

The other side gets a session of its own, so the two sign out
independently. Your server can make tokens with
`Authmk.Plugins.OneTimeToken.generate(MyApp.Auth, user.id)`. Options:
`expires_in` (180), `generate_token`, `disable_client_request` (no
`generate` endpoint), `disable_set_session_cookie` (a `token` in the answer
for `Authorization: Bearer`, instead of a cookie) and `deep_links` (see
[SPAs, desktop and mobile apps](api-clients.md)).

Tokens work once, expire fast, and are stored hashed. Whoever holds one
signs in as that user, without 2FA: never log it.

## Last sign-in method

So your sign-in page can say "You last used Google".

```elixir
use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.LastSignInMethod]
```

Each sign-in sets the `authmk.last_sign_in_method` cookie to `"email"`,
`"username"`, `"phone-number"`, `"email-otp"`, `"magic-link"`, `"passkey"`,
`"siwe"`, or the provider's id (`"github"`, `"google"`); after 2FA, the
first step's. Scripts can read it; servers call
`Authmk.Plugins.LastSignInMethod.get(conn, MyApp.Auth)`. With
`store_in_database: true`, the user keeps it too. The cookie may need
consent: pass `store_cookie: &MyApp.Consent.allowed?/2`, or `false`.
