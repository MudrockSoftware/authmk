# Security

authmk protects your users with safe defaults. A few things only your app
can decide: its secret, the origins it trusts, where the client's IP comes
from, and which extra defenses it wants. This guide covers both.

## What you get by default

  * Passwords are hashed with Argon2id (`Authmk.Password.Argon2`). Sign-in
    with an unknown email spends the same time as a wrong password, so
    response times don't reveal who has an account.
  * Session and verification tokens are stored as SHA-256 hashes
    (`Authmk.Token`), and one-time codes encrypted with your secret
    (`Authmk.OTP`). A database leak doesn't give anyone a usable token.
  * Session cookies are `HttpOnly`, `SameSite=Lax`, and `Secure` on HTTPS.
    See [Cookies across domains](cookies-and-domains.md).
  * State-changing requests from untrusted origins are refused, and
    redirects only go to relative paths or trusted origins.
  * Every endpoint is rate limited per client IP, and sign-in and sign-up
    more strictly.
  * Outbound requests (OAuth providers, captchas, Have I Been Pwned) never
    follow redirects and time out after 10 seconds (`Authmk.OAuth.HTTP`).

## Secrets

authmk signs and encrypts cookies, tokens and background jobs with one
secret. It refuses to start without one, or with one shorter than 32
characters, and warns when it looks low-entropy. Generate one with:

```sh
mix authmk.gen.secret
```

and set it as `AUTHMK_SECRET`. To rotate it without signing everyone out,
use versioned secrets, newest first, in `AUTHMK_SECRETS`:

```sh
AUTHMK_SECRETS="2:new-secret,1:old-secret"
```

New data uses version 2. Data made with version 1 stays readable until you
remove it. In config, the same is `secret: "..."` or
`secrets: [{2, "new"}, {1, "old"}]`; config wins over the environment. See
`Authmk.Secrets`, and [Deployment](deployment.md) for production setup.

## Trusted origins and CSRF

Browsers send an `Origin` header on cross-site requests. authmk checks it
(or `Referer`) on every request that isn't `GET`, `HEAD` or `OPTIONS`:

  * from a trusted origin: allowed;
  * from any other origin: refused with `invalid_origin` (403);
  * with neither header: allowed only when the request carries no cookies,
    since then it comes from a non-browser client and can't be forged.

The same list decides where authmk may redirect. A `callback_url` that is
neither a safe relative path nor a trusted origin is refused with
`invalid_callback_url`.

Your `base_url` is always trusted. Add others in config:

```elixir
trusted_origins: [
  "https://app.example.com",
  "https://*.preview.example.com",
  "myapp://"
]
```

`*` matches any characters except `/`, and `**` matches anything.
`"myapp://"` trusts a whole custom scheme, for mobile apps;
`"myapp://callback"` only that host. For origins that depend on the request
(a tenant's own domain), implement `c:Authmk.dynamic_trusted_origins/1` in
your auth module:

```elixir
@impl Authmk
def dynamic_trusted_origins(_ctx), do: MyApp.Tenants.custom_domains()
```

See `Authmk.Origin` for every pattern. `advanced: [disable_origin_check: true]`
turns the check off. Don't, unless something else protects you from CSRF.
Browser apps on other origins also need CORS; see
[SPAs, desktop and mobile apps](api-clients.md).

## Rate limiting

Each client IP gets a fixed window per endpoint path. The defaults: at most
100 requests per 10 seconds, and 3 per 10 seconds on sign-in, sign-up,
password reset and change. Plugins set their own, like the magic link's 5
per minute. Over the limit, the answer is `rate_limited` (429) with a
`Retry-After` header. IPv6 clients are grouped by their /64 prefix.

```elixir
rate_limit: [
  window: 60,
  max: 100,
  rules: %{
    "/sign-in/email" => [window: 60, max: 5],
    "/get-session" => false
  }
]
```

Rule keys are endpoint paths without the `/auth` prefix. `false` turns
limiting off for that path; `enabled: false` turns it off everywhere (handy
in tests).

Counters live in memory by default, so each node counts on its own. To share
them between nodes, pick a `storage:`:

  * `:memory` (the default): this node's ETS table.
  * `:secondary_storage`: your `secondary_storage`, like
    `{Authmk.Storage.Redis, conn: MyApp.Redix}` for Redis or Valkey.
  * `:database`: a `rate_limits` table, with the
    `Authmk.Plugins.DatabaseRateLimit` plugin. It costs a few queries per
    request, so prefer Redis under heavy traffic.

### The client's IP

Rate limits, the Security plugin and audit logs all key on the client's IP.
Behind a proxy or load balancer, every request comes from the proxy, so tell
authmk which header holds the real one with `advanced: [ip_address_headers:
[...]]`. Proxies append to `x-forwarded-for`, so authmk reads it from the
right: the first public address is the client's, and private ones (your
own proxies) are skipped. A header only your proxy sets, like
`cf-connecting-ip`, is better still: a header the client controls lets it
pick its own IP and dodge every limit. See [Deployment](deployment.md#behind-a-proxy).

## Captcha

`Authmk.Plugins.Captcha` puts a captcha in front of the endpoints bots like.
It supports Cloudflare Turnstile (`:turnstile`), Google reCAPTCHA v2 and v3
(`:recaptcha`), hCaptcha (`:hcaptcha`) and CaptchaFox (`:captchafox`).

```elixir
{Authmk.Plugins.Captcha,
 provider: :turnstile,
 secret_key: System.fetch_env!("TURNSTILE_SECRET")}
```

The client sends the widget's token in the `x-captcha-response` header. By
default `sign_up_email`, `sign_in_email` and `request_password_reset` need
one; `endpoints:` takes other endpoint names. For reCAPTCHA v3,
`min_score:` (default `0.5`) is the lowest score let through. hCaptcha and
CaptchaFox also check `site_key:` when you give it.

| Code | Status | Meaning |
| --- | --- | --- |
| `captcha_required` | 400 | No token was sent |
| `captcha_failed` | 403 | The provider refused it, or the score was too low |
| `captcha_unavailable` | 503 | The provider couldn't be reached |

The plugin fails closed: during a provider outage, bots don't get through,
and neither do people.

## The Security plugin

`Authmk.Plugins.Security` adds defenses against account attacks. Only
credential-stuffing blocking and disposable-email refusal are on by default;
the rest you turn on by option:

```elixir
{Authmk.Plugins.Security,
 sign_up_limit: [max: 3, window: 86_400],
 email: [check_mx: true],
 geo_lookup: &MyApp.GeoIP.lookup/1,
 impossible_travel: [action: :block],
 on_event: &MyApp.Alerts.security_event/2}
```

| Option | What it does | Error code |
| --- | --- | --- |
| `credential_stuffing` | Blocks an IP that fails sign-in 20 times, or for 5 accounts, in 10 minutes, for 15 minutes. `false` turns it off | `too_many_attempts` |
| `sign_up_limit` | At most `max` sign-ups per IP per `window` seconds | `too_many_sign_ups` |
| `email` | Refuses disposable addresses (`block_disposable`), domains without mail servers (`check_mx`), and one mailbox under many spellings (`unique_canonical`) | `disposable_email`, `email_cannot_receive_mail`, `email_already_used` |
| `velocity` | Per-user limits, like `velocity: [change_email: [max: 3, window: 86_400]]` | `velocity_limited` |
| `geo_lookup`, `geo_blocking` | `allowed_countries:` or `blocked_countries:`, from your GeoIP lookup | `region_blocked` |
| `impossible_travel` | With `geo_lookup`, flags sign-ins too far from the last one; `action: :block` refuses them | `sign_in_blocked` |
| `blocked_ips`, `ip_reputation` | IPs and CIDR ranges, or your own `fn ip -> :ok \| :block end` | `ip_blocked` |
| `block_bots` | Refuses sign-in and sign-up from known automation tools | `bot_blocked` |
| `proof_of_work` | `endpoints:` that need a solved challenge from `GET /auth/security/challenge` | `proof_of_work_required` |

`unique_canonical` tells a sign-up that its address is taken, which lets
anyone test whether an address has an account. Turn it on only if that
trade is worth it to you.

Each finding is a security event, `%{type:, ip:, user_id:, details:}`, given
to your `on_event` and emitted as telemetry (below). `inactive_users/2` lists
users who haven't signed in for a number of days, for a scheduled job.

## Have I Been Pwned

`Authmk.Plugins.HaveIBeenPwned` refuses passwords found in known data
breaches, on every endpoint that sets one: sign-up, password change and
reset, and the admin's.

```elixir
plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.HaveIBeenPwned]
```

Only the first five characters of the password's SHA-1 hash leave your
server, and answers are padded. A breached password gets
`password_compromised` (422). When the service can't be reached the
password is refused with `password_check_unavailable` (503), unless you set
`fail_open: true`. Check passwords in your own flows with
`Authmk.Plugins.HaveIBeenPwned.check/2`.

## Audit logs

`Authmk.Plugins.AuditLog` records who did what to which account, when, and
from where: users, sessions, accounts, verifications, and with
organizations, members and invitations. Events hold ids, roles and
providers, never tokens, codes or passwords.

```elixir
{Authmk.Plugins.AuditLog,
 can_view_all: &MyApp.Auth.admin?/1,
 retention_days: 365,
 destinations: [&MyApp.Audit.ship/1]}
```

Users read their own events at `GET /auth/audit-log/list`; those allowed by
`can_view_all` read everyone's at `GET /auth/audit-log/list-all`. From
server code, use `list_events/2`, and record your own events with `log/3`:

```elixir
Authmk.Plugins.AuditLog.log(MyApp.Auth, "report.exported",
  actor: conn.assigns.current_user,
  metadata: %{format: "csv"}
)
```

Events older than `retention_days` (default 90; `nil` keeps them forever)
are deleted at most once an hour, or when you call `prune/1`. A failing
destination is logged and never stops a sign-in.

## Logging

authmk logs little: crashes in an endpoint (with their stack trace), failed
token requests to OAuth providers, failing audit destinations or
`on_event` callbacks, and a low-entropy secret. Its messages are written to
leave out secrets, tokens, codes and passwords.

Messages sent through `Authmk.Log` carry `domain: [:authmk]`, so standard
Logger filters can silence or route them:

```elixir
# In Application.start/2
:logger.add_primary_filter(:no_authmk, {&:logger_filters.domain/2, {:stop, :sub, [:authmk]}})
```

Your own request logs are your app's job. Phoenix filters only `password`
from logged params by default; add authmk's other sensitive params:

```elixir
config :phoenix, :filter_parameters, ["password", "new_password", "token", "otp", "code"]
```

## Telemetry and OpenTelemetry

authmk emits these `:telemetry` events. Each carries `auth:`, your auth
module.

| Event | Metadata |
| --- | --- |
| `[:authmk, :endpoint, :start \| :stop \| :exception]` | `endpoint` (its name); on `:stop`, `result` (`:ok`, `:redirect`, `:error`...) |
| `[:authmk, :store, :start \| :stop \| :exception]` | `model`, `operation` |
| `[:authmk, :security, :event]` | `type`, `ip`, `user_id`, `details` |
| `[:authmk, :audit_log, :event]` | `event`, the recorded event as a map |

For example, to count failed requests per endpoint:

```elixir
:telemetry.attach("auth-errors", [:authmk, :endpoint, :stop], &MyApp.Metrics.auth_stop/4, nil)

def auth_stop(_event, %{duration: duration}, %{endpoint: endpoint, result: result}, _config) do
  MyApp.Metrics.record(endpoint, result, duration)
end
```

To turn them into OpenTelemetry spans, add `opentelemetry_api` and
`opentelemetry_telemetry` to your deps and call `Authmk.OpenTelemetry.setup/0`
once when your app starts. Each request becomes an `authmk <endpoint>` span,
with an `authmk.store <model> <operation>` span for each database call.

## Checklist

  * `AUTHMK_SECRET` (or `AUTHMK_SECRETS`) is random and kept out of git.
  * `base_url` is your public HTTPS URL, and `trusted_origins` lists only
    origins you control.
  * Behind a proxy, `ip_address_headers` names a header the client can't set.
  * With several nodes, rate limits use Redis or the database.
  * Add a captcha, the Security plugin and Have I Been Pwned where they fit.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's security advisories, never
in a public issue. See
[SECURITY.md](https://github.com/MudrockSoftware/authmk/blob/main/SECURITY.md).
