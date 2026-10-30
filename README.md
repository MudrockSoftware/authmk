# Authmk

Website: <https://authmk.com>

> **Status: early development.** The foundation, email/password, social
> sign-in, two-factor authentication and the passwordless sign-in methods
> work and are tested; more plugins are coming (see [ROADMAP.md](ROADMAP.md)).
> The API will change before 1.0.

## Why

Elixir has good building blocks for authentication: `phx.gen.auth`, Ueberauth,
Guardian, Assent, and Ash Authentication if you use Ash. What it doesn't have is
a framework where a plugin can add database tables, routes and lifecycle hooks
in one place, the way Better Auth does for TypeScript. Authmk aims to bring that
model to Phoenix and Ecto.

## Getting started

1. Add the dependency:

   ```elixir
   {:authmk, "~> 0.1.0"}
   ```

2. Define an auth module:

   ```elixir
   defmodule MyApp.Auth do
     use Authmk,
       otp_app: :my_app,
       repo: MyApp.Repo,
       plugins: [Authmk.Plugins.EmailPassword]

     @impl Authmk
     def send_reset_password(%{user: user, url: url}, _ctx) do
       MyApp.Mailer.deliver_reset_link(user.email, url)
     end
   end
   ```

3. Set a secret, configure, start it after your repo, and mount it:

   ```sh
   mix authmk.gen.secret            # put the output in AUTHMK_SECRET
   ```

   ```elixir
   # config/runtime.exs
   config :my_app, MyApp.Auth, base_url: "https://example.com"

   # application.ex
   children = [MyApp.Repo, MyApp.Auth, ...]

   # router.ex (Phoenix or Plug.Router)
   forward "/auth", MyApp.Auth
   ```

4. Generate and run the migration:

   ```sh
   mix authmk.gen.migration
   mix ecto.migrate
   ```

5. Load the signed-in user in your own pipelines:

   ```elixir
   plug Authmk.Plug.FetchSession, auth: MyApp.Auth   # assigns :current_user, :current_session
   plug Authmk.Plug.RequireAuthenticated, redirect_to: "/sign-in"
   ```

Clients then call `POST /auth/sign-up/email`, `POST /auth/sign-in/email`,
`GET /auth/get-session` and so on. See `Authmk.Endpoints` and
`Authmk.Plugins.EmailPassword` for every endpoint. Working Plug and Phoenix
apps are in [`examples/`](https://github.com/MudrockSoftware/authmk/tree/main/examples).

Social sign-in takes a line per provider, with 43 built in and any other
OpenID Connect or OAuth 2.0 provider through `:generic`:

```elixir
config :my_app, MyApp.Auth,
  social_providers: [
    github: [client_id: "...", client_secret: "..."],
    staff: [provider: :keycloak, issuer: "https://sso.example.com/realms/staff", client_id: "...", client_secret: "..."]
  ]
```

See the [social sign-in guide](guides/social-sign-in.md).

Two-factor authentication (authenticator apps, codes by email or SMS, backup
codes, trusted devices) is a plugin, and applies to every sign-in method:

```elixir
plugins: [
  Authmk.Plugins.EmailPassword,
  {Authmk.Plugins.TwoFactor, issuer: "My App", send_otp: &MyApp.Auth.send_two_factor_code/2}
]
```

See `Authmk.Plugins.TwoFactor`.

More sign-in methods, each a plugin:

| Plugin | What it adds |
|---|---|
| `Authmk.Plugins.Username` | Sign in with a username and password |
| `Authmk.Plugins.Anonymous` | Guests who sign up later, keeping their data |
| `Authmk.Plugins.PhoneNumber` | Codes by SMS; phone number and password |
| `Authmk.Plugins.MagicLink` | Sign-in links by email |
| `Authmk.Plugins.EmailOTP` | Codes by email: sign in, verify, reset, change email |
| `Authmk.Plugins.Passkey` | Passkeys (WebAuthn); needs `{:wax_, "~> 0.7"}` |
| `Authmk.Plugins.OneTap` | Google One Tap, popup and redirect modes |
| `Authmk.Plugins.SIWE` | Sign-In with Ethereum; needs `{:ex_secp256k1, "~> 0.8"}` and `{:ex_keccak, "~> 0.7"}` |

Your app as an identity provider: `Authmk.Plugins.OAuthProvider` makes it an
OAuth 2.1 authorization server and OpenID Connect provider, with PKCE,
consent, refresh-token rotation, resource indicators, DPoP, pushed
authorization requests, `private_key_jwt`, dynamic client registration and
logout. `Authmk.Plug.RequireAccessToken` protects your APIs with its tokens.

For business customers, `Authmk.Plugins.SSO` signs organizations in with
their own OpenID Connect identity providers, with DNS domain verification
and automatic provisioning, and `Authmk.Plugins.SCIM` lets their directories
(Okta, Entra ID, Google Workspace) provision and deprovision people and
groups over SCIM 2.0.

Authorization: `Authmk.AccessControl` defines roles and permissions, checked
without a database call. `Authmk.Plugins.Admin` manages users (roles, bans,
sessions, impersonation) with them, `Authmk.Plugins.Organization` adds
organizations with members, invitations, teams and their own roles, and
`Authmk.Plugins.APIKey` issues hashed API keys with permissions, usage
limits and rate limits, and `Authmk.Plugins.ServiceAccount` gives programs
their own identities (with roles, expiry and IP allow-lists), seen by your
plugs as `current_principal`.

Sessions and security, also plugins:

| Plugin | What it adds |
|---|---|
| `Authmk.Plugins.Bearer` | Sessions through `Authorization: Bearer` instead of cookies |
| `Authmk.Plugins.JWT` | JWTs from sessions, with a JWKS endpoint and key rotation |
| `Authmk.Plugins.MultiSession` | Several signed-in accounts on one device |
| `Authmk.Plugins.OneTimeToken` | Hand a signed-in user over to another app or domain |
| `Authmk.Plugins.DeviceAuthorization` | Sign-in on TVs and CLIs (RFC 8628) |
| `Authmk.Plugins.Captcha` | Turnstile, reCAPTCHA, hCaptcha or CaptchaFox on chosen endpoints |
| `Authmk.Plugins.HaveIBeenPwned` | Refuses passwords from known data breaches |
| `Authmk.Plugins.LastSignInMethod` | Remembers how a user last signed in, for "Last used" hints |
| `Authmk.Plugins.OAuthProxy` | Social sign-in on previews and localhost through production's callback URL |
| `Authmk.Plugins.AuditLog` | Who did what to which account, with retention and export |
| `Authmk.Plugins.Security` | Credential stuffing, sign-up abuse, email checks, impossible travel, geo and bot blocking, proof-of-work |
| `Authmk.Plugins.OpenAPI` | An OpenAPI 3.1 description of every enabled endpoint, and a reference page |

An admin dashboard (licensed separately: see License below) mounts in any
Plug or Phoenix router with one line,
`forward "/admin/auth", Authmk.Dashboard, auth: MyApp.Auth`: users,
sessions, two-factor, bans, organizations, SSO and SCIM, the audit log and
sign-in analytics, in Mudrock's light and dark themes.

When a social, SSO or One Tap sign-in, or an OAuth authorization, fails
with nowhere to send the user, authmk shows its own error page at
`/auth/error` (themed, light and dark, with the error code and a way back).
Pass `error_callback_url` (or set `errors: [error_url: ...]`) to send users
to your own page instead.

`Authmk.Emails` has ready-made Swoosh emails for every callback, and
`Authmk.SMS` is the behaviour for sending phone codes.

In your app's tests, `Authmk.Testing` creates users and sessions and signs
test conns in, and `Authmk.Testing.Inbox` catches the codes and links authmk
sends. To test passkey and wallet sign-in in your own app, `Authmk.Testing.FakeAuthenticator`
and `Authmk.Testing.FakeWallet` play the authenticator and the wallet.

## Design

### Plugins

A plugin is a module that implements the `Authmk.Plugin` behaviour. It can contribute:

- **Schema**: new tables, or extra fields on core tables such as `user`
- **Endpoints**: served under the auth router
- **Hooks**: `before_endpoint/2`, which can stop a request, `after_endpoint/3`,
  which can change the result, and `database_hook/4` around every write
- **Options**: validated in `init/1`

```elixir
defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    plugins: [
      {Authmk.Plugins.EmailPassword, require_email_verification: true},
      MyApp.Auth.AuditPlugin
    ]

  # Your auth module gets the same hooks as plugins.
  @impl Authmk
  def before_endpoint(:sign_up_email, ctx) do
    if String.ends_with?(ctx.raw_params["email"], "@example.com"),
      do: {:cont, ctx},
      else: {:halt, Authmk.Error.new(:forbidden)}
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}
end
```

### Schema declared in config

As in Better Auth, the schema is declared in config. Core models, plugin
models and your own settings are merged at compile time into one resolved
schema. That schema drives the Ecto schemas, input validation and migrations.

```elixir
use Authmk,
  repo: MyApp.Repo,
  table_naming: :plural,          # :plural (default) | :singular
  table_prefix: "auth_",          # optional
  schema: [
    user: [
      module: MyApp.Accounts.User,
      table: "users",             # an explicit table name always wins
      fields: [name: [source: :full_name]],
      additional_fields: [
        role: [type: :string, default: "user", input: false]
      ]
    ]
  ]
```

- **Table names:** an explicit `table:` wins; otherwise `table_prefix` plus the
  singular or plural model name.
- **References:** these point at models, not tables, so renaming a table
  updates every foreign key.
- **Existing databases:** you can map authmk onto tables you already have, such
  as `users` from `phx.gen.auth`, including renamed columns.

Models the library owns (sessions, accounts, verifications and so on) are
generated for you. Models you own, like the user, keep your own module and
pull in authmk's fields with a macro:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  use Authmk.Schema, auth: MyApp.Auth, model: :user

  schema "users" do
    authmk_fields()
    has_many :posts, MyApp.Blog.Post
    timestamps()
  end
end
```

### Migrations

Migrations are generated from the resolved schema. Authmk compares it with a
snapshot committed to your repo, similar to drizzle-kit, and writes normal
Ecto migrations:

```sh
mix authmk.gen.migration              # write a migration for schema changes
mix authmk.gen.migration --baseline   # record existing tables, write nothing
mix authmk.gen.migration --check      # fail in CI if a migration is missing
mix ecto.migrate
```

Destructive changes such as drops need `--allow-destructive`. Interactive
rename detection is planned.

### Databases

SQLite, PostgreSQL, MySQL and MariaDB are all supported through Ecto. Authmk follows
whichever adapter your repo uses, and there is no default.

To stay compatible with all of them, the schema only uses features they all
share. That means no array columns, no `citext`, no partial indexes, no
defaults computed by the database, and no defaults on `:text` or `:map` fields
(MySQL rejects them). IDs are generated by the app, emails are
normalized in code, and any field a plugin adds to an existing table must be
nullable or have a default, because SQLite can't change an existing column.

### Validation

Input is validated with Ecto changesets built from the field specs. That
means validation errors work with Phoenix forms (`to_form/1`) without any
adapter code.

### Language

Authmk is English only. Errors carry a stable `code`, such as
`:invalid_credentials`, so apps can show their own text if they want.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full feature plan toward 1.0.

## Installation

```elixir
def deps do
  [
    {:authmk, "~> 0.1.0"}
  ]
end
```

Documentation: <https://hexdocs.pm/authmk>

## Acknowledgements

Authmk's design borrows heavily from [Better Auth](https://github.com/better-auth/better-auth):
its plugin model, schema-in-config approach and CLI-driven schema generation.
Authmk is an independent project and is not affiliated with Better Auth.

## License

MIT © Mudrock Software LTD. See [LICENSE](https://github.com/MudrockSoftware/authmk/blob/main/LICENSE).

The admin dashboard and its analytics, in `licensed/`, aren't MIT licensed:
see [licensed/LICENSE.md](https://github.com/MudrockSoftware/authmk/blob/main/licensed/LICENSE.md).
They run freely in development and tests; elsewhere they need a licence key
in `AUTHMK_LICENCE_KEY` (keys: https://license.mudrock.dev).
