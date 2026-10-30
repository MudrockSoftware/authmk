# Changelog

authmk follows [Semantic Versioning](https://semver.org). See the
[stability guide](guides/stability.md) for what a version number promises,
and how to upgrade.

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
