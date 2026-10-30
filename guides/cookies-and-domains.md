# Cookies across domains

authmk's session cookie is `HttpOnly`, `SameSite=Lax`, and `Secure` with a
`__Secure-` prefix on HTTPS. That works out of the box when your frontend and
authmk share a host. Two setups need more thought.

## Frontend and API on different sites

```
Frontend: https://app.example-frontend.com
API:      https://api.example.com
```

Browsers treat the API's cookies as third-party. Safari's Intelligent
Tracking Prevention blocks them outright, and other browsers increasingly
do too: sign-in seems to work, then the user appears signed out.

There are two fixes.

### Proxy the API through the frontend's host

Serve authmk under the frontend's own domain, so its cookies are first-party:

```
https://app.example-frontend.com/auth/*  →  https://api.example.com/auth/*
```

Configure the rewrite in your hosting provider or reverse proxy, set
`base_url` to the frontend's URL, and the browser never sees another site.

### Use one parent domain

Put both on subdomains of one domain and share the cookie with the parent:

```
https://app.example.com
https://api.example.com
```

```elixir
config :my_app, MyApp.Auth,
  base_url: "https://api.example.com",
  trusted_origins: ["https://app.example.com"],
  cookies: [domain: "example.com"]
```

Every subdomain of `example.com` then receives the session cookie, so only do
this when you control all of them.

## Mobile apps and API clients

Clients that aren't browsers can't use `HttpOnly` cookies the same way: use
bearer tokens (`Authmk.Plugins.Bearer`). Requests without cookies or an
`Origin` header skip the browser CSRF check, since they can't be forged by a
website. See [SPAs, desktop and mobile apps](api-clients.md), which also
covers CORS for browser apps on other origins.

## Per-cookie settings

Each cookie can override its name, `SameSite` and domain:

```elixir
cookies: [session_token: [name: "sid", same_site: "Strict"]]
```

See `Authmk.Cookies`.
