# SPAs, desktop and mobile apps

Every authmk endpoint takes and answers JSON, so any client can use it.
What differs is how the client holds the session, and which origin it calls
from.

## Single-page apps

On the same site as authmk (or behind a proxy that makes it so, see
[Cookies across domains](cookies-and-domains.md)), an SPA needs nothing
special: `fetch("/auth/sign-in/email", {method: "POST", ...})` sets the
`HttpOnly` cookie, and later requests carry it.

On another origin, the browser lets the app *send* requests to authmk, but
not *read* the answers, unless authmk says so with CORS. Trust the app's
origin and turn on CORS for trusted origins:

```elixir
config :my_app, MyApp.Auth,
  trusted_origins: ["https://app.example.com"],
  cors: [trusted_origins: true]
```

```js
await fetch("https://api.example.com/auth/get-session", {credentials: "include"})
```

Answers to trusted origins carry `Access-Control-Allow-Origin: <that
origin>` and `Access-Control-Allow-Credentials: true`; other origins get no
CORS headers at all, so they can't read anything, and their changes are
refused as before. Cookies across sites still face the browsers' third-party
cookie rules: prefer one site, or bearer tokens.

## Desktop apps

Tauri, Electron and Capacitor webviews call from their own origins
(`tauri://localhost`, `capacitor://localhost`, `http://localhost:...`).
Trust that origin as above, or use bearer tokens.

## Bearer tokens

`Authmk.Plugins.Bearer` adds a `set-auth-token` header wherever the session
cookie is set. Keep it in the platform's secure storage (Keychain,
Keystore), never in `localStorage`, and send it back:

```
Authorization: Bearer <token>
```

It works like the cookie everywhere: expiry, refresh, revocation, and
`Authmk.Plug.FetchSession` in your own API.

## Mobile apps: social and SSO sign-in

OAuth and SAML sign-ins run in the system browser
(`ASWebAuthenticationSession` on iOS, Custom Tabs on Android), which keeps
its own cookies. To bring the session back to the app:

```elixir
use Authmk,
  trusted_origins: ["myapp://"],
  plugins: [
    Authmk.Plugins.Bearer,
    {Authmk.Plugins.OneTimeToken, deep_links: ["myapp://"], disable_set_session_cookie: true}
  ]
```

1. The app opens the sign-in with `callback_url: "myapp://signed-in"`.
2. After signing in, the browser goes to `myapp://signed-in?token=<one-time token>`.
3. The app posts the token to `/one-time-token/verify` and gets a bearer
   token of its own.

The one-time token works once and expires in three minutes, because another
app could register the same custom scheme. Where you can, use verified app
links (`https://`) on a host used only for them.

## CSRF

Requests with neither cookies nor an `Origin` header (native apps, servers)
skip the Origin check: a website can't make a browser send them. Requests
from browsers must come from a trusted origin.
