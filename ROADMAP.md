# Roadmap

This is the feature plan for the releases after authmk 1.0. Items are grouped
into milestones; each milestone builds on the previous ones. Everything ships
as core functionality or as a plugin built on the public plugin API. What 1.0
shipped is in [CHANGELOG.md](CHANGELOG.md).

Legend: `[ ]` planned, `[x]` done

---

## 1.1 Admin dashboard

The licensed dashboard (`licensed/`) grows from a browser into a place to run
the app's auth. Every page shows only what the app has set up: organization
pages need the Organization plugin, payments pages a payment plugin. Every
change made from the dashboard is written to the audit log.

### Dashboards

- [ ] More detailed analytics: active users over time, sign-ins and sign-ups by method, failed sign-ins, verification and 2FA adoption
- [ ] Filters by date range and organization, and exports

### Users and organizations

- [ ] Manage users: create, edit, verify email, ban, set a password, revoke sessions, unlink accounts, impersonate (with the Admin plugin)
- [ ] Manage organizations (with the Organization plugin): create, edit, delete, members and their roles, teams, invitations
- [ ] Custom fields: show, and edit where `input: true` allows it, the fields the app declares on users and organizations, by their types
- [ ] What a user can see and do: clicking a user shows their roles and permissions, per organization and team, with where each comes from, plus their sessions, linked accounts, API keys and 2FA methods

### Payments (with a payment plugin)

- [ ] Earnings: revenue, recurring revenue, new and cancelled subscriptions, by plan and provider
- [ ] Subscriptions: list them per user and organization, change plans, cancel and resume, through the configured provider

### Integrations

- [ ] Health checks: email and SMS senders, social and SSO providers (discovery, credentials, certificate expiry), SCIM, webhooks, payment providers, secondary storage and background jobs
- [ ] Warnings on the home page when a check fails or a certificate or secret is about to expire

### Branding and pages

- [ ] Custom branding: app name, logo and colours, used by the dashboard, authmk's pages and the email templates
- [ ] Customizable error pages: the app's own template, or authmk's page with its branding

---

## 1.x

Planned after 1.0, as minor releases. None of these change existing APIs.

### AI agents

- [ ] Agent identity, registration and discovery
- [ ] Capability-based authorization for agents
- [ ] Approval flows with configurable strength per method
- [ ] OpenAPI adapter that turns existing endpoints into agent capabilities
- [ ] Agent events and auditing

---

## Not planned

- **Translations**: authmk is English only. Errors carry stable codes so apps can show their own text.
- **Other databases or ORMs**: authmk only supports Ecto with SQLite, PostgreSQL and MySQL. No MongoDB or MSSQL.
- **Anonymous usage telemetry**: authmk never contacts a remote server. Observability uses `:telemetry` and OpenTelemetry instead.
- **Hosted services**: everything runs in your own application.
- **Vercel BotID**: use the Captcha plugin to stop bots.
