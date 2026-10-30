# Browser extensions

An extension talks to authmk from its own origin,
`chrome-extension://<extension id>` (or `moz-extension://<uuid>` in
Firefox), so authmk needs to trust it, and the extension needs somewhere to
keep the session.

## Trust the extension

```elixir
config :my_app, MyApp.Auth,
  trusted_origins: ["chrome-extension://abcdefghijklmnopabcdefghijklmnop"]
```

Without this, its sign-in requests are refused: they carry the extension's
`Origin`. Use the published extension's ID, which stays the same across
installs; development builds get their own.

## Keep a bearer token

Extensions can't count on cookies: whether the browser sends them from an
extension depends on the browser, its version and the user's settings. Use
`Authmk.Plugins.Bearer`, and keep the token in `chrome.storage.session`
(cleared when the browser closes) or `chrome.storage.local`:

```js
const response = await fetch("https://app.example.com/auth/sign-in/email", {
  method: "POST",
  headers: {"content-type": "application/json"},
  body: JSON.stringify({email, password})
})
const token = response.headers.get("set-auth-token")
await chrome.storage.session.set({token})
```

Give the extension `host_permissions` for your app's origin, so it can read
the header; then send the token on every call:

```js
fetch(url, {headers: {authorization: `Bearer ${token}`}})
```

## Social sign-in

`chrome.identity.launchWebAuthFlow` runs a sign-in in a browser window and
hands the extension the URL it ends at. Point the sign-in there, and have
authmk add a one-time token:

```elixir
use Authmk,
  trusted_origins: ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org"],
  plugins: [
    Authmk.Plugins.Bearer,
    {Authmk.Plugins.OneTimeToken,
     deep_links: ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org"],
     disable_set_session_cookie: true}
  ]
```

```js
const start = await fetch("https://app.example.com/auth/sign-in/social", {
  method: "POST",
  headers: {"content-type": "application/json"},
  body: JSON.stringify({provider: "github", callback_url: chrome.identity.getRedirectURL()})
})
const {url} = await start.json()
const finished = new URL(await chrome.identity.launchWebAuthFlow({url, interactive: true}))
const verify = await fetch("https://app.example.com/auth/one-time-token/verify", {
  method: "POST",
  headers: {"content-type": "application/json"},
  body: JSON.stringify({token: finished.searchParams.get("token")})
})
const {token} = await verify.json()
```

## Signing out

Post to `/sign-out` with the bearer token, then delete it from storage: the
session ends on the server, not only in the extension.
