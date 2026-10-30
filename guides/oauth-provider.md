# OAuth provider

Other apps sign their users in with your accounts ("Sign in with Acme"),
and get tokens for your APIs. `Authmk.Plugins.OAuthProvider` makes your app
an OAuth 2.1 authorization server and an OpenID Connect provider. It runs
the authorization code flow with PKCE, and the refresh token, client
credentials, device code and JWT bearer grants.

## Setup

The provider needs `Authmk.Plugins.JWT`, whose keys sign ID tokens. Most
OpenID Connect clients expect RS256, and the JWT plugin's default is EdDSA,
so set it:

```elixir
use Authmk,
  plugins: [
    Authmk.Plugins.EmailPassword,
    {Authmk.Plugins.JWT, algorithm: "RS256"},
    {Authmk.Plugins.OAuthProvider,
     login_page: "/sign-in",
     consent_page: "/consent",
     scopes: ["openid", "profile", "email", "offline_access", "read"]}
  ],
  ...
```

Then run `mix authmk.gen.migration` and `mix ecto.migrate`. `login_page`
and `consent_page` are your pages. `scopes` lists every scope clients may
ask for (default: `openid`, `profile`, `email` and `offline_access`).

## Registering clients

Register your own apps from server code, for example in a seed or a mix
task. Metadata uses RFC 7591's names:

```elixir
{:ok, client} =
  Authmk.Plugins.OAuthProvider.create_client(MyApp.Auth, %{
    "client_name" => "Acme CRM",
    "redirect_uris" => ["https://crm.example.com/callback"],
    "grant_types" => ["authorization_code", "refresh_token"],
    "scope" => "openid profile email offline_access"
  })

client.client_id
client.client_secret # shown only now; stored hashed
```

Options: `user_id:` and `reference_id:` (an organization) own the client;
`skip_consent: true` is for your own first-party apps (or list their ids in
`trusted_clients`).

What authmk checks on every registration:

  * Redirect URIs are HTTPS, or HTTP on `localhost` and loopback addresses.
    Native apps (`"application_type" => "native"`) may also use their own
    schemes, like `com.example.app:/callback`. Fragments and `javascript:`,
    `data:`, `vbscript:` and `file:` URIs are refused.
  * `token_endpoint_auth_method` is `client_secret_basic` (the default),
    `client_secret_post`, `private_key_jwt` or `none` (a public client, with
    no secret).
  * Public clients can't use `client_credentials` or the JWT bearer grant.
  * `scope` may only name the provider's `scopes`.
  * PKCE is required for every client. A confidential client may opt out
    with `"require_pkce" => false`.

Signed-in users can manage their own clients through
`POST /auth/oauth2/create-client`, `GET /auth/oauth2/get-client`,
`GET /auth/oauth2/get-clients`, `POST /auth/oauth2/update-client`,
`POST /auth/oauth2/delete-client` and `POST /auth/oauth2/client/rotate-secret`.
`client_privileges` decides who may do what, and `client_reference` lets
an organization's members share clients.

### Dynamic registration

With `allow_dynamic_client_registration: true`, clients register themselves
at `POST /auth/oauth2/register` (RFC 7591):

```http
POST /auth/oauth2/register
{"client_name": "MCP Inspector", "redirect_uris": ["http://localhost:6274/oauth/callback"]}

201 {"client_id": "...", "client_name": "MCP Inspector", "token_endpoint_auth_method": "none", ...}
```

By default this needs a signed-in user, who then owns the client. With
`allow_unauthenticated_client_registration: true`, anyone may register
public clients, and only those. Any origin may call it (10 a minute), but
the session only counts from trusted origins, so another site can't
register clients in a signed-in user's name.

### Client ID metadata documents

With `client_id_metadata_documents: true`, a client's `client_id` may be an
HTTPS URL that serves its metadata as JSON, as MCP clients do. There is no
registration step: authmk fetches the document when the client shows up,
and again when it goes stale (after its `max-age`, between 5 minutes and a
day). The fetch is guarded: HTTPS only, no redirects, at most 5 KB and 5
seconds, and never to private, loopback or link-local addresses. The
document's `client_id` must equal its URL, and it can't hold a secret, so
these clients are public or use `private_key_jwt`. A document that can't
be fetched again isn't trusted.

## Signing in

A client sends the user to the authorization endpoint:

```
GET /auth/oauth2/authorize?response_type=code&client_id=...
    &redirect_uri=https://crm.example.com/callback&scope=openid%20email
    &state=...&nonce=...&code_challenge=...&code_challenge_method=S256
```

  1. If the user isn't signed in, they go to your `login_page` with
     `client_id`, `scope` and `oauth_query`. After they sign in, your page
     posts `oauth_query` to `POST /auth/oauth2/continue` and follows the
     `url` it gets back.
  2. If they haven't agreed to these scopes for this client, they go to
     your `consent_page` with the same parameters. Show what the client
     is (`GET /auth/oauth2/public-client?client_id=...` gives its name,
     logo and links), then post the answer:

     ```http
     POST /auth/oauth2/consent
     {"oauth_query": "...", "accept": true}

     200 {"redirect": true, "url": "https://crm.example.com/callback?code=...&state=...&iss=..."}
     ```

     `scope` may narrow what was asked. `accept: false` sends the client
     `access_denied`.
  3. The client trades the code for tokens:

     ```http
     POST /auth/oauth2/token
     Authorization: Basic <client_id:client_secret>

     grant_type=authorization_code&code=...&redirect_uri=...&code_verifier=...

     200 {"access_token": "...", "token_type": "Bearer", "expires_in": 3600,
          "scope": "openid email offline_access", "refresh_token": "...", "id_token": "eyJ..."}
     ```

A refresh token comes only with the `offline_access` scope, and only for
clients registered with the `refresh_token` grant. An ID token comes only
with `openid`.

`prompt=none`, `prompt=login`, `prompt=consent` and `max_age` work as
OpenID Connect describes. `prompt=login` and `max_age` need a sign-in made
after the request, not before.

### What's verified

  * Until the redirect URI is known to be registered for the client, errors
    go to authmk's error page, never to the URI.
  * Redirect URIs match exactly. Native apps may use any port on a
    loopback URI (RFC 8252). `validate_redirect_uri` can replace the rule.
  * Only `S256` PKCE is accepted. A code issued with a challenge needs its
    verifier, and one issued without can't be redeemed with one.
  * `oauth_query` is signed and expires after 10 minutes, so the request
    can't change between your pages.
  * A code works once, for its client and redirect URI, for 60 seconds
    (`code_expires_in`), and only while the session it came from is alive.
  * Codes, access tokens, refresh tokens and client secrets are stored
    hashed.
  * Refresh tokens rotate on every use. A used token still works for
    `refresh_token_reuse_interval` seconds (10), for a client retrying a
    lost answer. After that, using it again revokes the whole chain.

`POST /auth/oauth2/par` takes pushed authorization requests (RFC 9126);
`require_pushed_authorization_requests: true` makes them mandatory. Clients
with `"dpop_bound_access_tokens" => true` must use DPoP (RFC 9449).

## The other endpoints

  * `GET` or `POST /auth/oauth2/userinfo` answers with the user's claims
    for an access token with the `openid` scope: `sub`, `name`, `picture`
    and `updated_at` with `profile`, `email` and `email_verified` with
    `email`, plus your own from the `claims` option. Your claims can't
    replace protocol ones like `sub` or `iss`.
  * `POST /auth/oauth2/introspect` (RFC 7662) tells a confidential client
    whether a token is active, with its `scope`, `client_id`, `sub` and
    `exp`. Inactive and unknown tokens get `{"active": false}`.
  * `POST /auth/oauth2/revoke` (RFC 7009) revokes a token, only for the
    client it was issued to. Revoking a refresh token revokes its chain and
    the access tokens it gave out. Unknown tokens get the same `200`.
  * `GET /auth/oauth2/end-session` signs users out (OpenID Connect
    RP-Initiated Logout). With an `id_token_hint` from the current session
    they're signed out at once; otherwise they confirm on your
    `logout_page`. When a session ends, clients with a
    `backchannel_logout_uri` are told with a signed logout token, and the
    access tokens that session gave out end with it.

The token, introspection and revocation endpoints authenticate the client
with the method it registered: HTTP Basic, `client_secret` in the body,
a `private_key_jwt` assertion, or for public clients only `client_id`.

## Discovery

authmk serves `/auth/.well-known/openid-configuration` and
`/auth/.well-known/oauth-authorization-server`. Clients look for them at
your app's root, so add `Authmk.Plug.WellKnown` early in your endpoint or
router:

```elixir
plug Authmk.Plug.WellKnown, auth: MyApp.Auth
```

It serves both at the root, also with the issuer's path after them
(`/.well-known/oauth-authorization-server/auth`), to any origin. Other
requests pass through. The signing keys are at `/auth/jwks` (`jwks_uri`).
The `metadata` option changes what the documents advertise.

## Protecting your API

Check access tokens with `Authmk.Plug.RequireAccessToken`:

```elixir
pipeline :api do
  plug Authmk.Plug.RequireAccessToken, auth: MyApp.Auth, scopes: ["read"]
end
```

With a valid token, the conn gets `:access_token`, `:current_user` (`nil`
for client credentials tokens) and `:current_principal`. Without one it
halts with a 401, or a 403 for a missing scope, with a `WWW-Authenticate`
header that says why. DPoP-bound tokens must come as
`Authorization: DPoP <token>` with a proof for that request.

Elsewhere, call `Authmk.Plugins.OAuthProvider.verify_access_token/3`.

### Tokens for other services

List your APIs in `resources`. A client then asks for a token for one with
the `resource` parameter (RFC 8707), and gets a JWT (RFC 9068) with the
resource as its `aud`, signed with the JWT plugin's keys. The API can check
it alone with the JWKS. A resource outside `resources` is refused with
`invalid_target`, and a code or refresh token can't be traded for another
resource than the one approved.

## MCP servers

MCP clients find this server, register and get tokens on their own:

```elixir
{Authmk.Plugins.OAuthProvider,
 login_page: "/sign-in",
 consent_page: "/consent",
 resources: ["https://example.com/mcp"],
 allow_dynamic_client_registration: true,
 allow_unauthenticated_client_registration: true}
```

Publish the MCP server's metadata (RFC 9728), and protect its route:

```elixir
plug Authmk.Plug.WellKnown,
  auth: MyApp.Auth,
  protected_resources: [
    [resource: "https://example.com/mcp", scopes: ["openid"], name: "My MCP server"]
  ]

plug Authmk.Plug.RequireAccessToken,
  auth: MyApp.Auth,
  resource: "https://example.com/mcp",
  resource_metadata: "https://example.com/.well-known/oauth-protected-resource/mcp"
```

A client without a token gets a 401 whose `WWW-Authenticate` header points
at the metadata. From there it finds this server, registers itself, and
asks for a token with `resource` set to the MCP server's URL. Registration,
token and user info allow CORS, so this works from a browser too. Each
protected resource must be one of the provider's `resources`.

## Devices and CLIs

Add `Authmk.Plugins.DeviceAuthorization` for the device code grant (RFC
8628). The device asks for codes, the user approves on your
`verification_uri` page, and the device polls the provider's token
endpoint:

```elixir
{Authmk.Plugins.DeviceAuthorization,
 verification_uri: "https://example.com/device",
 validate_client: &(Authmk.Plugins.OAuthProvider.public_client(MyApp.Auth, &1) != nil)}
```

```http
POST /auth/device/code
{"client_id": "...", "scope": "openid"}

200 {"device_code": "...", "user_code": "BCDF-GHJK", "verification_uri": "https://example.com/device", ...}
```

Your page looks the code up with `GET /auth/device?user_code=...`, shows
which client asks, and posts `user_code` to `POST /auth/device/approve` or
`POST /auth/device/deny`. The device polls `POST /auth/oauth2/token` with
`grant_type=urn:ietf:params:oauth:grant-type:device_code`, its
`device_code` and `client_id` (and `resource`, for an MCP server), and gets
`authorization_pending` or `slow_down` until the user decides. The client
must be registered with that grant type. Device codes are stored hashed
and work once. Without `validate_client`, any string may ask for codes as
its `client_id`, and your page would show it; the token endpoint still
refuses clients that aren't registered.
