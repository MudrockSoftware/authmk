# Roadmap

This is the full feature plan for authmk 1.0. Items are grouped into
milestones; each milestone builds on the previous ones. Everything ships as
core functionality or as a plugin built on the public plugin API.

Legend: `[ ]` planned, `[x]` done

---

## 0.1 Foundation

### Configuration
- [ ] `use Authmk` config validated with NimbleOptions, with clear compile-time errors
- [ ] `app_name`, `base_url`, `base_path` (default `/auth`)
- [ ] Dynamic base URL: work out the URL per request for preview deployments and multiple domains, with a safe fallback
- [ ] `secret` plus `secrets` for key rotation (sign and encrypt with the newest key, verify with all keys)
- [ ] `disabled_paths` to turn off individual endpoints
- [ ] `on_api_error` handler and configurable error redirect page
- [ ] Logger integration: log levels and a custom log function
- [ ] Background tasks: run non-critical work (emails, cleanup) on a `Task.Supervisor`, swappable for Oban

### Plugin system
- [ ] `Authmk.Plugin` behaviour: `init/1`, `schema/1`, `routes/1`, `hooks/1`, `depends_on/0`
- [ ] Plugin endpoints with param specs, validated by schemaless changesets
- [ ] Plugin schema: new models, and new fields on core models
- [ ] Before and after hooks, matched on a single endpoint, several endpoints, or a predicate
- [ ] Middleware for groups of plugin endpoints
- [ ] `on_request` / `on_response` callbacks
- [ ] Per-plugin rate-limit rules
- [ ] Plugins can add trusted origins
- [ ] Plugin dependency check and predictable hook order
- [ ] Helper functions for plugin authors (session lookup, sensitive-session check, cookie helpers)
- [ ] Guide: writing your first plugin

### Schema system
- [ ] Core models: `user`, `session`, `account`, `verification`
- [ ] Field specs: `type`, `required`, `default`, `input`, `returned`, `unique`, `index`, `references`, `on_delete`, `validate`, `source`
- [ ] Extra fields on core models (`additional_fields`)
- [ ] Rename fields and columns
- [ ] Table naming: `:plural` / `:singular`, `table_prefix`, per-model `table:` override
- [ ] Map onto existing tables, such as `users` from `phx.gen.auth`
- [ ] ID generation: app-generated UUIDs (default), integer IDs, custom generator function
- [ ] Mixed ID types (for example, integer user IDs with UUID plugin tables)
- [ ] `authmk_fields()` macro for models the user owns
- [ ] Generated modules for models the library owns
- [ ] Startup check that the database matches the resolved schema
- [ ] Database hooks: before and after create, update and delete on every model, able to change or cancel the operation
- [ ] Efficient loading of related records (one query for session plus user)
- [ ] Default limit for list queries

### Databases
- [ ] SQLite, PostgreSQL and MySQL through Ecto, chosen automatically from the repo's adapter
- [ ] A rule that schemas only use features all three share, checked at compile time
- [ ] CI test matrix across all three databases

### Mix tasks
- [ ] `mix authmk.install`: set up config, router, user schema and first migration (Igniter)
- [ ] `mix authmk.gen.migration`: snapshot diff and Ecto migration
- [ ] `mix authmk.gen.migration --baseline` for existing databases
- [ ] `mix authmk.gen.migration --check` for CI
- [ ] Interactive rename detection; destructive changes need `--allow-destructive`
- [ ] Table rebuild for SQLite when a column changes
- [ ] Run migrations from code (for releases)
- [ ] `mix authmk.gen.secret`
- [ ] `mix authmk.create_admin`
- [ ] `mix authmk.info`: versions, enabled plugins, resolved schema and config problems
- [ ] `mix authmk.upgrade`: guided upgrades between authmk versions

### Secondary storage
- [ ] `Authmk.Storage` behaviour (get, set with TTL, delete)
- [ ] Built-in ETS storage
- [ ] Redis storage (Redix)
- [ ] Used for sessions, rate limits and verification values

### Errors and observability
- [ ] `%Authmk.Error{}` with stable codes, documented in an error reference
- [ ] `:telemetry` events for every endpoint and database operation
- [ ] OpenTelemetry spans for endpoints and database calls

---

## 0.2 Core authentication

### Email and password
- [ ] Sign up, sign in and sign out
- [ ] "Remember me" (session cookie vs. persistent cookie)
- [ ] Password hashing with Argon2id by default (configurable cost), with Bcrypt and custom hash and verify functions available
- [ ] Minimum and maximum password length
- [ ] Turn sign-up on or off
- [ ] Callback for duplicate sign-up attempts that doesn't reveal whether the email is taken
- [ ] Fake user response so sign-up and sign-in can't be used to find existing emails
- [ ] Request password reset, reset password and the reset callback
- [ ] Optionally sign out every session after a password reset
- [ ] Change password, with an option to sign out other sessions
- [ ] Set a password for accounts that only use social sign-in
- [ ] Verify a password (server-side check before sensitive actions)

### Email verification
- [ ] `send_verification_email` callback; bring your own mailer (Swoosh)
- [ ] Send on sign-up, send on sign-in, or both
- [ ] Require a verified email before sign-in
- [ ] Verification link endpoint with a callback URL
- [ ] Sign the user in automatically after verification
- [ ] Callbacks before and after verification

### Sessions
- [ ] Database-backed sessions with IP address and user agent
- [ ] Session lifetime and how often it's extended
- [ ] Turn off session extension, or defer it
- [ ] Session freshness for sensitive actions
- [ ] Get, list, update and sign out sessions; sign out other sessions; sign out all sessions
- [ ] Cookie cache to skip database lookups, as signed, encrypted or JWT cookies
- [ ] Cookie-cache JWTs signed with keys from a JWKS endpoint
- [ ] Sessions in secondary storage, optionally also kept in the database
- [ ] Stateless sessions (no database), with cache refresh and versioning for revocation
- [ ] Custom session response (add or reshape fields)

### Users and accounts
- [ ] Update user details
- [ ] Change email, with verification of the current and/or new address
- [ ] Delete a user, optionally with email verification, freshness check and before/after callbacks
- [ ] List linked accounts
- [ ] Encrypt OAuth tokens stored in the database
- [ ] Update account data on each sign-in

### Cookies
- [ ] Cookie prefix and custom cookie names
- [ ] Custom cookie attributes, per cookie and as defaults
- [ ] Cookies shared across subdomains
- [ ] Secure cookies forced on in production
- [ ] Guide: Safari ITP and cross-domain setups (reverse proxy, shared parent domain)

### Security
- [ ] CSRF protection and origin checks for requests that change state
- [ ] Trusted origins: fixed list, wildcards, custom schemes (for mobile apps), dynamic list per request
- [ ] OAuth state and PKCE on every OAuth flow
- [ ] Protection against revealing which emails are registered, across all endpoints
- [ ] Trusted proxy headers and configurable IP address headers
- [ ] Option to turn off IP tracking
- [ ] Outbound HTTP requests don't follow redirects (protects against server-side request forgery)
- [ ] Security policy and vulnerability reporting process

### Rate limiting
- [ ] On by default in production, with a default window and maximum
- [ ] Rules per endpoint (stricter defaults for sign-in, sign-up and password reset)
- [ ] Storage in memory, the database or secondary storage
- [ ] IPv6 support with subnet grouping
- [ ] `Retry-After` header and a standard error response

---

## 0.3 Social sign-in

### OAuth core
- [ ] Sign in with a social provider (redirect flow)
- [ ] Sign in with an ID token (native mobile and one-tap flows)
- [ ] Link and unlink accounts
- [ ] Account linking rules: trusted providers, allowing different emails, allowing the last account to be unlinked
- [ ] Get an access token, with automatic refresh
- [ ] Get account info from the provider
- [ ] Ask for extra scopes later, and keep previously granted scopes across sign-ins
- [ ] Custom authorization URL parameters, `prompt`, `response_mode`
- [ ] Pass extra data through the OAuth flow
- [ ] Map a provider profile to a user, including placeholder emails for providers that return none
- [ ] Validate provider user info before creating a user
- [ ] Per-provider options: `disable_sign_up`, `disable_implicit_sign_up`, `disable_id_token_sign_in`, `verify_id_token`, `override_user_info_on_sign_in`, `require_email_verification`, `disable_default_scope`, custom `get_user_info`, custom `refresh_access_token`
- [ ] OAuth state stored in a cookie or in the database
- [ ] One identity-token verifier shared by all providers
- [ ] Documented error codes for OAuth callbacks

### Built-in providers
- [ ] Apple
- [ ] Atlassian
- [ ] Amazon Cognito
- [ ] Cloudflare
- [ ] Discord
- [ ] Dropbox
- [ ] Facebook
- [ ] Figma
- [ ] GitHub
- [ ] GitLab
- [ ] Google
- [ ] Hugging Face
- [ ] Kakao
- [ ] Kick
- [ ] LINE
- [ ] Linear
- [ ] LinkedIn
- [ ] Microsoft
- [ ] Naver
- [ ] Notion
- [ ] Paybin
- [ ] PayPal
- [ ] Polar
- [ ] Railway
- [ ] Reddit
- [ ] Roblox
- [ ] Salesforce
- [ ] Slack
- [ ] Spotify
- [ ] TikTok
- [ ] Twitch
- [ ] Twitter (X)
- [ ] Vercel
- [ ] VK ID
- [ ] WeChat
- [ ] Zoom

### Generic OAuth plugin
- [ ] Any OAuth 2.0 / OpenID Connect provider, configured by discovery URL or by hand
- [ ] Ready-made settings for Auth0, Gumroad, HubSpot, Keycloak, LINE, Microsoft Entra ID, Okta, Patreon, Slack and Yandex
- [ ] Custom token exchange and user-info fetch
- [ ] Map user-info fields; access the raw token response
- [ ] Sign in with an ID token
- [ ] Sign-in started from the identity provider
- [ ] Logout started from the app, sent on to the identity provider

---

## 0.4 Sign-in methods

### Two-factor authentication
- [ ] Turn 2FA on and off (with password confirmation)
- [ ] TOTP with an otpauth URI and QR code (NimbleTOTP)
- [ ] One-time codes by email or SMS
- [ ] Backup codes: generate, view, use, regenerate
- [ ] Trusted devices (skip 2FA for a set time)
- [ ] Configurable issuer
- [ ] Option to skip verification when enabling
- [ ] Option to enable 2FA without a password

### Username
- [ ] Sign up and sign in with a username
- [ ] Update a username; check if one is available (or turn that check off)
- [ ] Minimum and maximum length, custom validator
- [ ] Separate display username, with its own validation and normalization
- [ ] Usernames that can't be changed

### Anonymous
- [ ] Sign in anonymously
- [ ] Link to a real account later, with an `on_link_account` callback
- [ ] Delete the anonymous user after linking (optional)
- [ ] Custom email domain, generated email and name

### Phone number
- [ ] Send and verify OTP codes (bring your own SMS sender)
- [ ] Sign up on verification; sign in with phone number and password
- [ ] Update and remove a phone number
- [ ] Password reset by OTP
- [ ] Limit on verification attempts
- [ ] Custom validator; option to require verification; option to verify without creating a session

### Magic link
- [ ] Send a magic link and verify it
- [ ] Sign up through a magic link (optional)
- [ ] Custom token generation and storage (plain or hashed)

### Email OTP
- [ ] Send, check and sign in with an OTP
- [ ] Verify an email with an OTP, optionally replacing link-based verification
- [ ] Reset a password with an OTP
- [ ] Change an email with an OTP
- [ ] Limit on attempts; codes stored hashed or encrypted

### Passkeys (WebAuthn)
- [ ] Register and sign in with passkeys (Wax)
- [ ] Register a passkey as the first sign-in method, before any account exists
- [ ] Autofill passkey sign-in (conditional UI)
- [ ] List, rename and delete passkeys
- [ ] Name passkeys after the authenticator (AAGUID lookup)
- [ ] Extensions: PRF, largeBlob, credProps

### Google One Tap
- [ ] One Tap sign-in with ID-token verification
- [ ] Custom redirect behavior; authorized-origin checks

### Sign-In with Ethereum
- [ ] Generate a nonce, verify the signed message (EIP-4361)
- [ ] Messages for specific chains; identity taken from the signed message
- [ ] Optional ENS name and avatar lookup

---

## 0.5 Authorization

### Access control
- [ ] Shared roles and permissions system (statements, roles, `has_permission?/2`)
- [ ] Custom permissions and roles, checked on the server
- [ ] Permissions that can be checked offline, without a database call

### Admin
- [ ] Create, list (with search, filter, sort and pagination), get, update and remove users
- [ ] Set a user's role and password
- [ ] Ban and unban users, with a reason and an expiry; custom message for banned users
- [ ] List and revoke a user's sessions
- [ ] Impersonate a user and stop impersonating, with a time limit
- [ ] Admin roles, admin user IDs, default role
- [ ] Access control for admin actions

### Organizations
- [ ] Create, list, get (including members and invitations), update and delete organizations
- [ ] Active organization per session
- [ ] Invitations: send, accept, cancel, reject, get, list (for an organization and for a user), with email callbacks
- [ ] Members: list, add, remove, update role, get the active member and their role, leave
- [ ] Organization roles and permissions, including custom permissions
- [ ] Dynamic access control: create, update, delete and list roles at runtime
- [ ] Teams: create, update, delete, list; team members; active team; team permissions
- [ ] Hooks on organization lifecycle events
- [ ] Extra fields on organization, member, invitation and team
- [ ] Limits (organizations per user, members per organization)

### API keys
- [ ] Create, verify, get, update, delete and list API keys; delete expired keys
- [ ] Sessions created from API keys (sign requests in with an `x-api-key` header)
- [ ] Multiple key configurations (prefixes, lengths, defaults) chosen by ID
- [ ] API keys owned by an organization, with permission checks
- [ ] Per-key permissions, defaults and checks for required permissions
- [ ] Per-key rate limiting
- [ ] Remaining-use count, refills and expiry
- [ ] Storage in the database, secondary storage, or both
- [ ] Custom key generation and verification; metadata
- [ ] Keys stored hashed

### Service accounts
- [ ] `service_account` model: a non-human identity owned by a user or an organization, with no email, no password and no interactive sign-in
- [ ] Authenticates with API keys, or with the client credentials grant when the OAuth provider plugin is enabled
- [ ] Roles and permissions through the shared access-control system, including organization roles
- [ ] Create, list, update, disable and delete; rotate credentials without downtime (overlapping keys)
- [ ] Optional expiry and IP allow-list
- [ ] Unified principal: plugs and LiveView assign `current_principal` (a user or a service account), alongside `current_user`
- [ ] Service accounts appear as the actor in audit logs and are counted separately in admin analytics
- [ ] Admin and organization endpoints and UI to manage them

---

## 0.6 Tokens and utilities

- [ ] **Bearer tokens**: authenticate API and mobile requests with `Authorization: Bearer`
- [ ] **JWT**: issue JWTs from a session; JWKS endpoint (custom path, remote URL); key algorithms EdDSA, ES256, RS256 and more; private keys encrypted at rest (can be turned off); key rotation; custom signing; customizable payload, issuer, audience, subject and expiry; custom key storage
- [ ] **Multiple sessions**: several signed-in accounts per device; list, switch, revoke; maximum session count
- [ ] **One-time tokens**: generate and verify single-use tokens (for cross-domain hand-off)
- [ ] **Device authorization** (RFC 8628): device code, user code, polling, approve and deny, client validation, custom code generation, binding to a user in advance, choice of token type
- [ ] **Captcha**: Cloudflare Turnstile, Google reCAPTCHA (v2 and v3 with score threshold), hCaptcha, CaptchaFox, Vercel BotID; per-endpoint
- [ ] **Compromised passwords**: Have I Been Pwned k-anonymity check; custom message; applies to custom password flows
- [ ] **Last sign-in method**: cookie and optional database field; cross-domain support; can be turned off for GDPR
- [ ] **OAuth proxy**: OAuth sign-in on preview deployments and localhost through a production callback
- [ ] **OpenAPI**: generate an OpenAPI spec for all enabled endpoints, plus a reference UI
- [ ] **Test helpers**: ExUnit factories, database helpers, sign-in helpers for `Plug.Test` / LiveView tests, captured OTPs and emails

---

## 0.7 Identity provider and enterprise

### OAuth 2.1 / OpenID Connect provider
- [ ] Authorize, token, consent, continue, introspect, revoke, user-info and end-session endpoints
- [ ] Discovery metadata (`/.well-known/openid-configuration`, OAuth authorization-server metadata) with customizable advertised values
- [ ] Grant types: authorization code with PKCE, refresh token, client credentials, device code, JWT bearer
- [ ] Dynamic client registration, including unauthenticated registration with provider policy
- [ ] Client create, read, update and delete, with privilege rules
- [ ] Consent screen and redirect screens
- [ ] Scopes, claims (custom claims can't override protocol claims), resources and protected resources
- [ ] Client authentication: `client_secret_basic`, `client_secret_post`, `private_key_jwt`, tied to the grant
- [ ] DPoP (sender-constrained tokens)
- [ ] Pushed authorization requests (PAR)
- [ ] Pairwise subject identifiers
- [ ] Refresh-token rotation that tolerates retries
- [ ] `max_age` enforcement
- [ ] Back-channel logout; logout started from the app, with browser confirmation
- [ ] Cached trusted clients; custom redirect-URI validation
- [ ] Organization-aware clients and tokens
- [ ] Standard OAuth error responses everywhere
- [ ] Token verification helpers for resource servers

### MCP authorization
- [ ] Act as the OAuth provider for MCP clients
- [ ] Protected resource metadata
- [ ] Plug for protecting MCP routes
- [ ] Device authorization for your own CLI tools
- [ ] Optional fallback to dynamic client registration

### Client ID metadata documents
- [ ] Discover OAuth clients from HTTPS metadata documents
- [ ] Draft-02 validation, persistence and refresh, clear security boundaries

### Single sign-on
- [ ] Register OIDC providers, with discovery
- [ ] Register SAML 2.0 providers
- [ ] Sign-in started from the service provider and from the identity provider
- [ ] Service provider metadata endpoint
- [ ] Signed SAML authentication requests; rotating signing certificates
- [ ] SAML attribute mapping
- [ ] SAML protections: request/response matching, replay protection, timestamp checks, algorithm allow-list, size limits
- [ ] Default SSO provider; shared redirect URI
- [ ] Domain verification (DNS TXT record)
- [ ] User and organization provisioning on sign-in
- [ ] Resolve which SSO user to sign in

### SCIM provisioning
- [ ] SCIM 2.0 users and groups endpoints
- [ ] Filtering, pagination, PATCH and discovery endpoints
- [ ] Compatibility with Microsoft Entra ID groups
- [ ] Bearer credentials per connection: verification and rotation
- [ ] Map groups to custom roles and reconcile changes
- [ ] Link provisioned users to existing users; callbacks to resolve and reconcile users
- [ ] Handle deactivation and deletion; decommission connections
- [ ] Sign provisioned users in through SSO

---

## 0.8 Security, auditing and admin UI

### Audit logs
- [ ] Record user, session, account, verification and organization events
- [ ] Query the current user's events and all events (admin)
- [ ] Retention settings; export to log destinations

### Security plugin
- [ ] Credential-stuffing detection
- [ ] Impossible-travel detection
- [ ] Free-trial abuse prevention
- [ ] Compromised-password detection
- [ ] Inactive-account monitoring
- [ ] Geo-blocking
- [ ] Bot blocking and suspicious-IP detection
- [ ] Velocity limits
- [ ] Email validation (disposable domains, MX check) and normalization (plus-addressing, dots)
- [ ] Proof-of-work challenges with adjustable difficulty
- [ ] Security events sent through hooks and `:telemetry`

### Admin dashboard (Phoenix LiveView)
- [ ] Users, sessions, organizations, teams and invitations
- [ ] SSO connections and directory sync
- [ ] Event and audit-log browser
- [ ] Sign-in and sign-up analytics
- [ ] Two-factor management
- [ ] Mounted in the app's router, behind admin access control

### Messaging
- [ ] Ready-made email templates for verification, password reset, magic links, OTPs and invitations (Swoosh)
- [ ] SMS sender behaviour for OTP delivery

---

## 0.9 Framework integration

- [ ] Plug: `Authmk.Plug.FetchSession`, `RequireAuthenticated`, `RequireRole`, `RequireUser` (rejects service accounts)
- [ ] Phoenix router macro and controller helpers
- [ ] LiveView: `on_mount` hooks, `current_user` / `current_session` assigns
- [ ] LiveView function components: sign-in, sign-up, password reset, 2FA, passkeys, account settings, organization switcher
- [ ] JSON API usable by SPAs, mobile apps and desktop apps
- [ ] Deep-link and custom-scheme redirects for mobile apps
- [ ] Browser extension guide
- [ ] Performance guide (cookie cache, secondary storage, indexes)
- [ ] Migration guides from `phx.gen.auth`, Pow and Ash Authentication

---

## Payments and integrations (plugins)

- [ ] Stripe: customers, subscriptions, checkout, customer portal, webhooks, trials, lifecycle hooks, organization subscriptions, tax collection
- [ ] Polar: checkout, customer portal, usage events and meters, webhooks
- [ ] Chargebee: customers, subscriptions, hosted pages, webhooks, trials
- [ ] Creem: checkout, customer portal, access checks, webhooks, trial-abuse prevention
- [ ] Dodo Payments: checkout, customer portal, webhooks
- [ ] Autumn: pricing and billing logic
- [ ] Commet: customer portal, subscriptions, feature access, usage, seats, webhooks
- [ ] Dub: lead tracking and OAuth linking

---

## AI agents

- [ ] Agent identity, registration and discovery
- [ ] Capability-based authorization for agents
- [ ] Approval flows with configurable strength per method
- [ ] OpenAPI adapter that turns existing endpoints into agent capabilities
- [ ] Agent events and auditing

---

## 1.0

- [ ] Every milestone above complete
- [ ] Stable public API and plugin API, with a deprecation policy
- [ ] Full HexDocs guides and a complete error reference
- [ ] Independent security review
- [ ] Test suite passing on SQLite, PostgreSQL and MySQL

---

## Not planned

- **Translations**: authmk is English only. Errors carry stable codes so apps can show their own text.
- **Other databases or ORMs**: authmk only supports Ecto with SQLite, PostgreSQL and MySQL. No MongoDB or MSSQL.
- **Anonymous usage telemetry**: authmk never contacts a remote server. Observability uses `:telemetry` and OpenTelemetry instead.
- **Hosted services**: everything runs in your own application.
