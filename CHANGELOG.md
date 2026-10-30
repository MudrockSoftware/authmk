# Changelog

authmk follows [Semantic Versioning](https://semver.org). See the
[stability guide](guides/stability.md) for what a version number promises,
and how to upgrade.

## 1.1.0 (unreleased)

The admin dashboard grows from a browser into a place to run your app's
auth. Every page shows only what the app has set up, and every change made
from the dashboard is written to the audit log (`dashboard.*` events, with
the admin as the actor). Run `mix authmk.gen.migration` after upgrading if
you add `Authmk.Dashboard.Branding` or new fields.

### Dashboard (licensed, see `licensed/LICENSE.md`)

- **Analytics**: active users, sign-ins and sign-ups per day and by method,
  failed sign-ins and why, email verification and second-factor adoption,
  for a date range (up to a year) and an organization's members. CSV
  exports of users, audit events and the daily figures, with spreadsheet
  formulas neutralised, capped at 50,000 rows and audited.
- **Users**: create, edit (name, email, picture and the fields your schema
  declares, by their types, where `input: true` allows), verify emails, set
  passwords and roles, ban with a reason and duration, revoke sessions,
  unlink accounts (never the last one), impersonate and delete. A new email
  set by an admin isn't verified until someone verifies it. Changes run
  through `Authmk.Plugins.Admin`'s endpoints, so its rules hold.
- **What a user can see and do**: their roles and permissions in the app and
  in each organization (built-in or the organization's own) and team,
  where each comes from, and their sessions, linked accounts, API keys and
  second factors.
- **Organizations**: create, edit, delete, members and their roles, teams
  and invitations, as an app admin who isn't a member.
- **Payments**: recurring revenue from the plans' prices, by plan and
  provider and per currency; new and cancelled subscriptions; subscriptions
  per user and organization; changing plans, cancelling and resuming
  through the provider.
- **Integrations**: health checks of email and SMS senders, social and SSO
  providers (discovery, client credentials, certificate and client-secret
  expiry), SCIM connections, payment webhooks, secondary storage, background
  jobs and the audit log, with warnings on the home page.
- **Branding**: `Authmk.Dashboard.Branding`, a plugin that keeps the app's
  name, logo and colour, edited in the dashboard and used by the dashboard,
  authmk's pages and `Authmk.Emails`. The logo is served from your app at
  `<base URL>/branding/logo`, so that nothing in it runs. Without a licence
  key outside development, pages and emails keep authmk's look.
- New Admin permissions for the dashboard: `organization: create, update,
  delete`, `subscription: update` and `branding: update`, granted to the
  default `admin` role. Custom access control that includes
  `Authmk.Plugins.Admin.Permissions.statements()` gets them too.

### Library

- **Branding hook**: plugins may implement the new optional
  `c:Authmk.Plugin.branding/1` (app name, logo URL, primary colour).
  `Authmk.Branding.get/1` merges it over the config, drops invalid values
  and works out a readable text colour; the error page and `Authmk.Emails`
  use it. A branding plugin that fails falls back to the defaults.
- **Your own error page**: `errors: [page: {module, function}]` renders the
  app's template at `/auth/error`, with the error and the branding. If it
  raises, authmk's page is shown instead.
- **Payments**: plans take optional prices (`amount`, `annual_amount`,
  `currency`, in minor units, checked at startup).
  `Authmk.Payments.change_plan/4`, `cancel/3` and `resume/2` manage
  subscriptions from server code through the provider (Stripe, Polar,
  Chargebee, Creem, Dodo Payments and Commet), saved as webhooks save them,
  so lifecycle hooks fire. `monthly_amount/2`, `active?/1`, `provider/1` and
  `supports?/2` are new, and so are the optional `change_plan/4` and
  `resume/3` callbacks of `Authmk.Payments.Provider`. New error codes:
  `subscription_canceled`, `not_scheduled_to_cancel`, `not_supported` and
  `plan_change_needs_payment`.
- **Organizations from server code**: `Authmk.Plugins.Organization` gains
  `create_organization/3`, `update_organization/3`, `delete_organization/2`,
  `invite_member/6`, `cancel_invitation/2`, and with teams `create_team/3`,
  `update_team/3`, `remove_team/2`, `add_team_member/3` and
  `remove_team_member/3`. They make the endpoints' checks, minus the
  caller's own permissions, and run the hooks. Invalid ids now give
  not-found errors instead of raising, in `add_member/4`,
  `set_member_role/4` and `remove_member/3` too.
- **Audit log**: sign-ins and sign-ups record how (`metadata.method`:
  `"email"`, a provider's id, `"passkey"`, `"sso"`, `"two-factor"`...), and
  failed sign-ins are recorded as `sign_in.failed`, with the method and the
  error code, never the email tried.
- `Authmk.Plugins.LastSignInMethod` now also records Apple's form-post
  social callbacks.

## 1.0.0

The first stable release. Its public API, plugin API, endpoints and error
codes are covered by the [stability guide](guides/stability.md) from here
on.

Everything planned for 1.0: email and password, sessions, social sign-in
with more than 40 built-in providers, two-factor authentication, passkeys,
magic links and one-time codes, organizations and access control, admin,
API keys and service accounts, an OAuth 2.1 and OpenID Connect provider with
MCP authorization, SAML and OIDC single sign-on, SCIM provisioning, audit
logs, the Security plugin, payments, and SQLite, PostgreSQL, MySQL and
MariaDB support.

### Security

Found while documenting 1.0, and fixed before release:

- **Admin roles had no ceiling.** A custom admin role with a few actions,
  like `user: [:set_password]`, could use them on stronger accounts, admins
  included, and `user: [:set_role]` could hand out any role, its own
  included. An admin now needs every admin permission a user has to change
  them, sign in as them or give them a role (`Admin.can_manage?/3`). The
  dashboard checks the same.
- **Organization roles had no ceiling either.** With custom roles, someone
  allowed to invite or update members could invite or promote people to a
  stronger role than their own. They now need every management permission
  the role grants.
- **SSO providers could create verified accounts for any email.** Anyone may
  register a provider, and new users took its `email_verified` claim.
  Social sign-in then linked those accounts. Only a provider's verified
  domain makes an email verified now.
- **SCIM `link_existing_users` reached past the organization.** With
  organizations, a connection now only links users who are already members
  of its organization. A provider tied to an organization only accepts that
  organization's connections, and an email changed through SCIM becomes
  unverified.
- **Pairwise OAuth clients could learn users' ids** from JWT access tokens
  and introspection. Both now give the client its pairwise subject.
- **Client IPs could be spoofed** behind proxies that append to
  `x-forwarded-for`: authmk read the leftmost address, which the client
  controls. It now reads from the right, skipping private addresses.
- **`change-email` revealed which emails have accounts.** It answers the same
  for taken addresses now, without changing or sending anything; so does
  `email-otp/request-email-change`.
- **Old change-email links kept working** after a later change, so a link
  sent to a mistyped address could still move the account there. Links and
  codes now only work from the address they were issued for.
- **Password resets by code left other sessions signed in.** Resets by
  email code or SMS code now end them, like resets by link, and run
  `on_password_reset`.
- **A failed OAuth token request could log tokens** from a response in an
  unexpected shape. Only the status and OAuth error fields are logged.
- **SSRF guards are checked when connecting.** Requests to URLs someone
  else chose resolve the host, refuse it unless every address is public,
  and connect to the address that was checked, so DNS rebinding can't
  reach a private network (`Authmk.OAuth.HTTP.public_hosts_only/1`). This
  covers client metadata documents and SSO providers registered at
  runtime, now including the token, user info and JWKS endpoints their
  discovery documents list, which weren't checked before and must be
  HTTPS. It also covers OAuth clients' `jwks_uri` and
  `backchannel_logout_uri`, except for `trusted_clients`.
- **Passkey and SIWE sign-ups no longer hold unproven emails.** The account
  gets a placeholder email, and the address it was given gets a change-email
  link; the address joins the account, verified, when the link is opened.
  Before, anyone could take an address this way, keep its owner from
  signing up, and wait in the account the owner would reach with a magic
  link or a password reset. Both endpoints take an optional `callback_url`
  for that link.
- **Unverified emails change through a link too.** `POST /change-email`
  used to move an unverified account to the new address at once; now the
  new address gets the link, as for verified ones, so no account holds an
  address nobody proved.
- **SIWE nonces can't be cancelled by others.** Asking for a nonce used to
  replace the wallet's pending one, so anyone could keep a wallet's sign-in
  failing. Each nonce now stands alone, and still works once.
- **Phone codes are limited per number.** `send_limit` (5 an hour by
  default) caps codes to one number from any client, against SMS pumping;
  reset requests count before the number is looked up.
- **Bcrypt refuses new passwords over 72 bytes** with `password_too_long`,
  instead of ignoring the rest. Passwords set before keep working.
- **Device authorization**: with the OAuth provider, only its registered
  clients with the device code grant get codes, for scopes they may ask
  for. The scope is checked again before an approved code is used up.

### Added

- Google One Tap `require_nonce: true` and `POST /one-tap/nonce`: a
  credential only works with an unused nonce from authmk, so a leaked one
  can't be replayed.
- EmailPassword `reset_password_page`: where reset links go when they were
  requested without `redirect_to`. Without either, the link ends on the
  error page (it used to answer with a JSON error) and a warning is logged.
- The optional `c:Authmk.Password.max_bytes/0` callback, and
  `Authmk.PasswordPolicy.check/4`.
- SCIM: a user deactivated by `DELETE` (`on_delete: :deactivate`) can be
  provisioned again by the same connection, with their account and SCIM id.

### Changed

- `revoke_sessions_on_password_reset` defaults to `true`: a reset ends every
  session, since whoever knew the old password may still be signed in.
- The Security plugin's `unique_canonical` docs said it was on by default;
  it's off, as before.
- Migration, schema-resolution and OAuth-flow internals are no longer
  documented; they were never meant to be called.
- Every log message goes through `Authmk.Log`, so `domain: [:authmk]`
  filters catch the billing, SSO, Stripe, Dub, Autumn, last sign-in method
  and dashboard messages too.

### Fixed

- Google One Tap's redirect mode is recorded by `LastSignInMethod`.
- The dashboard's lists failed on MySQL.
