# Enterprise SSO and SCIM

Business customers want their people to sign in with the company's
identity provider (Okta, Entra ID, Google Workspace...), and want accounts
created and removed from their directory. `Authmk.Plugins.SSO` does the
first, with OpenID Connect or SAML 2.0. `Authmk.Plugins.SCIM` does the
second, with SCIM 2.0. Each organization usually gets its own provider and
its own SCIM connection.

## Setup

```elixir
use Authmk,
  plugins: [
    Authmk.Plugins.EmailPassword,
    Authmk.Plugins.Organization,
    {Authmk.Plugins.SSO, can_manage: &MyApp.Auth.org_admin?/3},
    {Authmk.Plugins.SCIM, can_manage: &MyApp.Auth.org_admin?/3}
  ],
  ...

# In your auth module: may the signed-in user manage this organization's SSO and SCIM?
def org_admin?(_action, organization_id, ctx), do: MyApp.Accounts.org_admin?(ctx.user, organization_id)
```

Then run `mix authmk.gen.migration` and `mix ecto.migrate`.

`can_manage` is `fn action, organization_id, ctx -> boolean end`. Without
it, nobody manages an organization's providers or connections through the
endpoints. `Authmk.Plugins.Organization` is optional: with it, users that
SSO or SCIM create join the organization.

## SSO providers

A signed-in user registers a provider. An OpenID Connect one:

```http
POST /auth/sso/register
{"provider_id": "acme", "issuer": "https://acme.okta.com", "domain": "acme.com",
 "organization_id": "...", "oidc_config": {"client_id": "...", "client_secret": "..."}}

200 {"provider_id": "acme", "type": "oidc", "issuer": "https://acme.okta.com",
     "domain": "acme.com", "domain_verified": false, "organization_id": "...", "client_id": "..."}
```

`provider_id` is lowercase letters, digits and dashes. The issuer must be
an HTTPS URL on a public host that answers OpenID Connect discovery;
authmk fetches it when you register, and refuses private network
addresses. The client secret is stored encrypted and never shown again.
`oidc_config` may also take `scopes` (default `openid email profile`).

The customer registers `<base URL>/auth/sso/callback/<provider_id>` as the
redirect URI at their identity provider. With `shared_redirect_uri: true`,
every provider uses `/auth/sso/callback`.

A provider without `organization_id` belongs to the user who registered it.
One with an `organization_id` needs `can_manage` for `:register`, `:read`
and `:delete`. `GET /auth/sso/providers` lists them (pass
`organization_id` for an organization's), and `POST /auth/sso/delete-provider`
removes one.

Providers can also come from config, as `default_providers`. Their domains
count as verified:

```elixir
{Authmk.Plugins.SSO,
 default_providers: [
   [provider_id: "acme", issuer: "https://acme.okta.com", domain: "acme.com",
    client_id: "...", client_secret: "..."]
 ]}
```

Pass a function of no arguments instead of the list to read secrets from
runtime config.

### SAML

Register a SAML provider with `saml_config` instead of `oidc_config`:
either the identity provider's `metadata` (its XML), or its `entity_id`,
`sso_url` and `certificates` (PEM). It may also take `slo_url`, `mapping`
and `allow_idp_initiated`.

```http
POST /auth/sso/register
{"provider_id": "acme", "domain": "acme.com", "saml_config": {"metadata": "<EntityDescriptor ..."}}
```

Give the customer's admin this provider's metadata URL,
`<base URL>/auth/sso/saml2/metadata/<provider_id>`, which is also your
entity ID. The assertion consumer service URL is
`<base URL>/auth/sso/saml2/acs/<provider_id>`.

To sign authentication requests, and to decrypt encrypted assertions, give
the plugin RSA keys:

```elixir
{Authmk.Plugins.SSO,
 saml: [signing_keys: [[private_key: File.read!("sp.key"), certificate: File.read!("sp.crt")]]]}
```

The first key signs. All are published in the metadata, so you can announce
a new key before you switch to it. Without keys, requests go unsigned.

A SAML response must:

  * be signed (the Assertion or the Response) with one of the provider's
    certificates, with RSA or ECDSA and SHA-256 or stronger;
  * answer the request this browser started (`InResponseTo`), unless the
    provider has `allow_idp_initiated: true`;
  * be for this provider (audience, recipient, destination and issuer), and
    within its time limits, give or take `saml: [clock_skew: 120]` seconds;
  * not have been used before: each assertion signs in once.

Encrypted assertions use RSA-OAEP with AES-GCM. AES-CBC is refused unless
`saml: [allow_aes_cbc: true]`, because XML Encryption's CBC mode has known
padding-oracle attacks. XML is parsed with OTP's `xmerl`, with DTDs and
entities refused. A refused response sends the user to the error page with
`invalid_saml_response`; the reason is only in your logs.

The user's email and name come from the assertion's attributes. Common
names (`email`, `mail`, `givenName`, `displayName`, Microsoft's and the
standard OIDs) work as they are; set `mapping` for others, like
`%{"email" => "urn:custom:mail"}`.

With an `slo_url`, `POST /auth/sso/saml2/logout` ends the session and
answers with the provider's URL, so the user is signed out there too. A
signed LogoutRequest from the provider ends the sessions its sign-in made
(sessions must be stored in the database).

## Signing in

```http
POST /auth/sign-in/sso
{"email": "ada@acme.com", "callback_url": "/dashboard"}

200 {"url": "https://acme.okta.com/...", "redirect": true}
```

authmk finds the provider by `provider_id`, `organization_id`, or the
domain of `email` (or `domain`). Send the browser to `url`. When it comes
back, the user is signed in and sent to `callback_url`, or to
`new_user_callback_url` when they're new. Errors go to
`error_callback_url` as `?error=<code>`. Like social sign-in, the flow is
bound to the browser that started it, and two-factor authentication still
applies.

### Domain verification

A provider proves it owns its domain with a DNS TXT record:

```http
POST /auth/sso/request-domain-verification
{"provider_id": "acme"}

200 {"record": "_authmk-sso.acme.com", "value": "authmk-sso-verification=..."}
```

The customer publishes the record, then you call
`POST /auth/sso/verify-domain` with the same `provider_id`. It answers
`{"domain_verified": true}`, or the error `domain_not_verified` while DNS
hasn't caught up.

Until the domain is verified (with `domain_verification: true`, the
default):

  * emails at that domain aren't routed to the provider; it must be named
    by `provider_id` or `organization_id`;
  * it can't sign in a user who already has an account with that email,
    so a provider can't take over accounts by claiming their emails. The
    user gets `account_not_linked`.

### Which user signs in

In order:

  1. your `resolve_user` function, if it picks one
     (`fn profile, provider, ctx -> {:ok, user} | {:error, error} | :default end`);
  2. the user this provider's identity was linked to before;
  3. the existing user with that email, when the provider's domain is
     verified, or a SCIM connection tied to the provider created the user;
  4. a new user, unless `disable_sign_up: true`.

A sign-in without an email fails with `email_required`. New users join the
provider's organization with `organization_role` (`"member"`). A new
user's email counts as verified when the provider's verified domain owns
it. The provider's own `email_verified` claim doesn't count: anyone can add
a provider, and other sign-in methods trust verified emails.

### Testing SAML

`Authmk.Testing.SAMLIdP` stands in for an identity provider in your tests.
Configure a provider whose certificate pairs with a test key, then:

```elixir
conn = post(build_conn(), "/auth/sign-in/sso", %{provider_id: "acme"})

%{acs_url: acs_url, params: params} =
  Authmk.Testing.SAMLIdP.response(json_response(conn, 200)["url"],
    issuer: "https://idp.acme.com/saml",
    private_key: File.read!("test/fixtures/idp.key"),
    name_id: "ada@acme.com",
    attributes: %{"email" => ["ada@acme.com"]}
  )
```

The identity provider's page posts `params` to `acs_url` as a form,
without your cookies. Then the browser follows the redirect to
`/auth/sso/saml2/finish` with its cookies, and is signed in.
`Authmk.Testing.SAMLIdP.build/1` makes responses from explicit values, for
IdP-initiated, expired, unsigned or encrypted cases.

## SCIM provisioning

Each directory gets a connection to one organization, with its own bearer
token:

```http
POST /auth/scim/connections
{"organization_id": "...", "name": "Okta", "provider_id": "acme"}

200 {"id": "...", "organization_id": "...", "provider_id": "acme", "name": "Okta",
     "status": "active", "created_at": "...", "token": "scim_..."}
```

Or from server code, with
`Authmk.Plugins.SCIM.create_connection(MyApp.Auth, organization_id: org.id)`.
The token is stored hashed and shown only now. The customer sets their
directory up with `<base URL>/auth/scim/v2` and that token.

`GET /auth/scim/connections?organization_id=...` lists connections.
`POST /auth/scim/connections/rotate-token` gives a new token; the old one
stops at once. `POST /auth/scim/connections/decommission` ends a
connection: its token stops working, and the people it provisioned are
deactivated and signed out. Each takes `connection_id` and needs
`can_manage`.

### Endpoints

Under `/auth/scim/v2`, with `Authorization: Bearer <token>`:

  * `Users` and `Groups`: `GET` and `POST`; `Users/:id` and `Groups/:id`:
    `GET`, `PUT`, `PATCH` and `DELETE`
  * `ServiceProviderConfig`, `ResourceTypes` and `Schemas`, for discovery

Answers use `application/scim+json` and SCIM's error format, with
`scimType` such as `uniqueness` or `invalidFilter`. PATCH takes the forms
Okta and Entra ID send. Lists take `startIndex`, `count` (at most
`max_results`, 100) and `filter`:

```
GET /auth/scim/v2/Users?filter=userName eq "ada@acme.com"
```

Filters support `eq`, `ne`, `co`, `sw`, `ew` and `pr`, with `and`, `or`
and parentheses, on `userName`, `externalId`, `active`, `displayName`,
`emails`, `name.givenName` and `name.familyName` for users, and
`displayName` and `externalId` for groups. Strings compare
case-insensitively. Filters are length- and depth-limited and become Ecto
queries, so nothing reaches SQL unescaped.

### What gets created and removed

  * A connection only sees what it provisioned, never another
    connection's users or groups.
  * `POST /Users` needs `userName` and an email (in `emails`, or a
    `userName` that is one). It creates a user, with the email unverified,
    and adds them to the organization with `default_role` (`"member"`).
  * An email that already has an account is refused with `uniqueness`,
    so a directory can't take over accounts. `link_existing_users: true`
    links them instead, but with organizations only people who are
    already members of the connection's organization. `resolve_user`
    lets you decide yourself. A changed email becomes unverified.
  * `active: false` deactivates a user: they keep their account, can't
    sign in by any method, and their sessions end.
  * `DELETE /Users/:id` deactivates too, or deletes the user with
    `on_delete: :delete`.
  * With `group_roles` (`fn group_display_name -> role | nil end`), group
    members get organization roles. A user in several groups gets the
    first role in `role_priority` (`owner`, `admin`, `member`). Mapping a
    directory group to `owner` gives the directory that power.

A connection with a `provider_id` ties its users to that SSO provider: the
provider may sign in the users the connection provisioned, even before
its domain is verified.
