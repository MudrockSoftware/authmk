# Social sign-in

Users sign in with an account they already have elsewhere: GitHub, Google,
Apple, your company's identity provider. authmk runs the OAuth 2.0
authorization code flow with PKCE, verifies OpenID Connect ID tokens, and
links the provider's account to a local user.

## Setup

Add providers to your auth module with their client credentials:

```elixir
use Authmk,
  social_providers: [
    github: [client_id: System.fetch_env!("GITHUB_CLIENT_ID"), client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET")],
    google: [client_id: "...", client_secret: "...", access_type: "offline"]
  ],
  ...
```

Register `<base_url>/auth/callback/<provider>` as the redirect URI at the
provider (`/auth` is the default `base_path`). Each provider's module docs
(`Authmk.OAuth.Providers.GitHub` and so on) say where to create the app and
what it needs. `Authmk.OAuth.Providers` lists the options every provider
takes.

Built in: Apple, Atlassian, Auth0, Cloudflare, Cognito, Discord, Dropbox,
Facebook, Figma, GitHub, GitLab, Google, Gumroad, HubSpot, Hugging Face,
Kakao, Keycloak, Kick, LINE, Linear, LinkedIn, Microsoft, Naver, Notion,
Okta, Patreon, Paybin, PayPal, Polar, Railway, Reddit, Roblox, Salesforce,
Slack, Spotify, TikTok, Twitch, Twitter (X), Vercel, VK ID, WeChat, Yandex
and Zoom. Any other OpenID Connect or OAuth 2.0 provider works through
`:generic` (below).

## Signing in

The client asks for the provider's authorization URL and sends the user
there:

```http
POST /auth/sign-in/social
{"provider": "github", "callback_url": "/dashboard"}

200 {"url": "https://github.com/login/oauth/authorize?...", "redirect": true}
```

The provider sends the user back to `/auth/callback/github`, which signs
them in and redirects to `callback_url`. Other parameters:

  * `new_user_callback_url` - where new users go instead
  * `error_callback_url` - where errors go (default: `errors: [error_url: ...]`,
    or `/auth/error`), as `?error=<code>`
  * `scopes` - scopes to ask for on top of the provider's defaults
  * `login_hint` - the account to suggest at the provider
  * `request_sign_up` - allow sign-up when the provider has
    `disable_implicit_sign_up: true`
  * `additional_data` - a JSON object (at most 1 KB) that comes back after
    the provider, in `ctx.private.oauth_additional_data`, for your callbacks
    and hooks

The flow is bound to the browser that started it: its state lives in an
encrypted cookie (or the database, with `account: [store_state: :database]`),
and a callback in another browser, or for another provider, fails.

### With an ID token

Native apps and one-tap flows already have an ID token from the provider.
They send it instead, and get the user back without a redirect:

```http
POST /auth/sign-in/social
{"provider": "google", "id_token": {"token": "eyJ...", "nonce": "..."}}
```

The token must be signed with the provider's keys and issued to `client_id`
(or one of the provider's `audience:` values, like an iOS bundle id). Only
providers with ID tokens accept this; `disable_id_token_sign_in: true` turns
it off.

## Accounts

A provider identity is an account of a user. On sign-in:

  * a known identity signs its user in;
  * a new identity whose email belongs to a user is linked to that user
    only when both sides verified the email (or the provider is in
    `account: [account_linking: [trusted_providers: [...]]]`), so nobody can
    take over an account by registering its email somewhere else;
  * otherwise a new user is created, unless the provider has
    `disable_sign_up: true`.

Signed-in users manage their accounts with:

  * `POST /auth/link-social` - link another provider (same parameters as
    sign-in); the provider's email must be the user's unless
    `account_linking: [allow_different_emails: true]`
  * `GET /auth/list-accounts` and `POST /auth/unlink-account` - the last
    account can't be unlinked unless `allow_unlinking_all: true`
  * `POST /auth/get-access-token` - the provider access token, refreshed
    when it expired
  * `POST /auth/refresh-token` - refresh now
  * `GET /auth/account-info?account_id=...` - the provider's current profile

Ask for more scopes later by linking the same provider again with `scopes`;
scopes granted before are kept. With `account: [encrypt_oauth_tokens: true]`,
tokens are encrypted at rest.

## Your say in it

`c:Authmk.map_social_profile/2` sees every provider user before sign-in, and
may change or refuse it:

```elixir
@impl Authmk
def map_social_profile(
      %{provider: :github, user: %{email: nil} = user, profile: profile},
      _ctx
    ),
    do: {:ok, %{user | email: "#{profile["id"]}@users.noreply.example.com"}}

def map_social_profile(%{user: %{email: email} = user}, _ctx) do
  if String.ends_with?(email, "@example.com"),
    do: {:ok, user},
    else: {:error, Authmk.Error.custom(:not_an_employee, 403, "Employees only")}
end
```

Per provider, `require_email_verification: true` refuses emails the
provider hasn't verified, and `override_user_info_on_sign_in: true` updates
the user's name and image on every sign-in.

For anything else (another user info call, a different token request, your
own ID token checks) write a provider module. It can reuse a built-in
one:

```elixir
defmodule MyApp.Auth.GitHubOrg do
  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider
  alias Authmk.OAuth.Providers.GitHub

  @impl true
  defdelegate config, to: GitHub

  @impl true
  defdelegate map_profile(profile, tokens), to: GitHub

  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, profile} <- GitHub.user_info(tokens, provider, ctx),
         {:ok, _membership} <-
           Provider.get_json(
             ctx,
             "https://api.github.com/user/memberships/orgs/acme",
             tokens.access_token
           ) do
      {:ok, profile}
    end
  end
end
```

and use it with `github: [provider: MyApp.Auth.GitHubOrg, client_id: ..., client_secret: ...]`.
`Authmk.OAuth.Provider` lists every callback.

## Any other provider

`provider: :generic` takes any OpenID Connect provider from its issuer
(the endpoints and keys come from its discovery document), or any OAuth 2.0
provider by hand:

```elixir
social_providers: [
  intranet: [
    provider: :generic,
    name: "Intranet",
    issuer: "https://sso.example.com",
    client_id: "...",
    client_secret: "...",
    id_token_sign_in: true
  ],
  legacy: [
    provider: :generic,
    authorize_url: "https://legacy.example/oauth/authorize",
    token_url: "https://legacy.example/oauth/token",
    userinfo_url: "https://legacy.example/api/me",
    disable_default_scopes: true,
    scopes: ["profile"],
    profile_map: [id: "uid", email: "mail", email_verified: nil]
  ]
]
```

See `Authmk.OAuth.Providers.Generic`. Auth0 (`domain:`), Keycloak and Okta
(`issuer:`) are presets of the same. `provider:` also takes a built-in
provider's name, to use one provider twice: `staff: [provider: :keycloak, ...]`.

### Sign-in started by the provider

With `idp_initiated_login: true`, the provider can start sign-in by sending
the user to `GET /auth/sign-in/initiate/<provider>?iss=<issuer>` (OpenID
Connect's initiate login URI), with an optional `login_hint` and
`target_link_uri` (where to go afterwards, a trusted URL). `iss` must be the
provider's issuer. An ordinary flow starts from there, so the user still
signs in at the provider in this browser.

### Signing out at the provider

`POST /auth/sign-out/social` with `provider` (and an optional
`callback_url`) signs the user out here and returns the provider's logout
URL, with the user's ID token as `id_token_hint` and `callback_url` as
`post_logout_redirect_uri` (register it at the provider). Providers find
the logout URL in their discovery document, or take `end_session_url:`.

## Error codes

Redirect flows end at `error_callback_url` with `?error=<code>`; the JSON
endpoints answer with `{"error": {"code": ...}}`.

| Code | Meaning |
| --- | --- |
| `oauth_provider_not_found` | No provider by that name |
| `invalid_callback_url` | A callback URL isn't a trusted origin |
| `state_not_found` | The callback came without `state` |
| `state_mismatch` | The flow wasn't started in this browser, for this provider, or expired |
| `no_code` | The callback came without a code |
| `invalid_code` | The provider refused the code |
| *the provider's own code* | The user declined, or the provider failed (like `access_denied`) |
| `invalid_id_token` | An ID token failed verification |
| `id_token_not_supported` | The provider takes no ID tokens |
| `discovery_failed` | The provider's discovery document couldn't be read or names another issuer |
| `unable_to_get_user_info` | The provider's profile couldn't be read or mapped |
| `email_not_found` | The provider shared no email |
| `email_not_verified` | `require_email_verification` and the provider didn't verify it |
| `sign_up_disabled` | New users can't sign up through this provider |
| `account_not_linked` | The email belongs to a user, and linking it isn't safe |
| `email_doesnt_match` | Linking: the provider's email isn't the user's |
| `account_already_linked_to_different_user` | Linking: the identity belongs to someone else |
| `forbidden` | A provider-started sign-in that isn't allowed |
