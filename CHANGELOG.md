# Changelog

authmk follows [Semantic Versioning](https://semver.org). See the
[stability guide](guides/stability.md) for what a version number promises,
and how to upgrade.

## Unreleased

Hardening from the 1.x roadmap.

### Security

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

- Every log message goes through `Authmk.Log`, so `domain: [:authmk]`
  filters catch the billing, SSO, Stripe, Dub, Autumn, last sign-in method
  and dashboard messages too.

## 1.0.0

The first stable release. Its public API, plugin API, endpoints and error
codes are covered by the [stability guide](guides/stability.md) from here
on.

Everything in the [roadmap](ROADMAP.md) up to 1.0: email and password,
sessions, social sign-in with more than 40 built-in providers, two-factor
authentication, passkeys, magic links and one-time codes, organizations and
access control, admin, API keys and service accounts, an OAuth 2.1 and
OpenID Connect provider with MCP authorization, SAML and OIDC single sign-on,
SCIM provisioning, audit logs, the Security plugin, payments, and SQLite,
PostgreSQL, MySQL and MariaDB support.

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

### Changed

- `revoke_sessions_on_password_reset` defaults to `true`: a reset ends every
  session, since whoever knew the old password may still be signed in.
- The Security plugin's `unique_canonical` docs said it was on by default;
  it's off, as before.
- Migration, schema-resolution and OAuth-flow internals are no longer
  documented; they were never meant to be called.

### Fixed

- Google One Tap's redirect mode is recorded by `LastSignInMethod`.
- The dashboard's lists failed on MySQL.
