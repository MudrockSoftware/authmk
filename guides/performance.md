# Performance

authmk's defaults favour correctness: every request reads its session from
the database, so a sign-out or a revoked session takes effect at once. Most
apps never need more. When they do, these are the levers, and what each
gives up.

## Measure first

authmk emits `[:authmk, :endpoint, :start | :stop | :exception]` telemetry
for every endpoint, with the endpoint's name, and spans for its database
calls (see `Authmk.OpenTelemetry`). Find the slow part before changing
anything.

## The cookie cache

```elixir
session: [cookie_cache: [enabled: true, max_age: 300]]
```

The session and user are copied into a signed (or `strategy: :encrypted`)
cookie, and `Authmk.Plug.FetchSession` and `GET /get-session` read it
instead of the database for `max_age` seconds. The cost: for up to
`max_age`, a revoked session still reads as signed in on those paths
(endpoints that change things always check the database). Keep `max_age`
short, and don't use the cache where an immediate sign-out matters, like an
admin area. Changing `version` invalidates every cached cookie at once.

## Secondary storage

```elixir
secondary_storage: {Authmk.Storage.Redis, conn: :redix}
```

Sessions, verification tokens and rate-limit counters move to Redis (or
`Authmk.Storage.ETS` on a single node). Session reads become key lookups.
With `session: [store_in_database: true]`, sessions are written to both,
so you keep a database record to list and audit them. Revocation stays
immediate: it deletes the stored session.

## Rate limiting

The default `rate_limit: [storage: :memory]` counts per node. Behind
several nodes, use `:secondary_storage` (one count for all) or `:database`
with `Authmk.Plugins.DatabaseRateLimit`, which costs a write per request.

## Sessions

`session: [update_age: 86_400]` decides how often a session's expiry is
pushed forward: a write at most once a day per session. With
`defer_refresh: true`, `GET /get-session` never writes; clients refresh with
`POST /get-session`.

## Indexes

Generated migrations index what authmk looks up: session tokens (unique),
user IDs on sessions and accounts, account provider and ID (unique),
verification identifiers, emails (unique), and each plugin's foreign keys.
Your own queries on authmk's tables (by `inserted_at`, by a field you
added) need your own indexes, in your own migrations.

## Password hashing

Argon2id is slow on purpose: a sign-in costs tens of milliseconds of CPU.
Don't lower its cost in production to speed sign-ins up; scale the nodes
instead. The fast settings in test configs are for tests only.

## Background work

`background: :task` (the default) sends emails and runs other side work
after the response, in a supervised task, so sign-up doesn't wait for your
mail provider.
