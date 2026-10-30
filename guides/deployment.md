# Deployment

## Secrets

authmk reads `AUTHMK_SECRET` at startup and refuses to start without one, or
with one shorter than 32 characters. Generate it with:

```sh
mix authmk.gen.secret
```

To rotate it without signing everyone out, switch to versioned secrets in
`AUTHMK_SECRETS`, newest first:

```sh
AUTHMK_SECRETS="2:new-secret,1:old-secret"
```

New cookies and tokens use version 2; ones made with version 1 keep working
until you remove it. Changing `AUTHMK_SECRET` without this signs everyone out.

## Base URL

Set `AUTHMK_BASE_URL` (the installer reads it in `config/runtime.exs`) to your
public URL, like `https://example.com`. authmk builds email links from it and
trusts it as an origin. For several domains or preview deployments, use an
allow list instead (see `Authmk.BaseURL`).

## Migrations in releases

authmk's migrations are normal Ecto migrations in `priv/repo/migrations`, so
the usual release migrator runs them:

```elixir
defmodule MyApp.Release do
  @app :my_app

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
```

Add `mix authmk.gen.migration --check` to CI, so a schema change can't ship
without its migration. With `advanced: [validate_schema: true]` the auth
module also checks the database at boot.

## Behind a proxy

Behind a load balancer, the connection's IP is the proxy's. Tell authmk which
header holds the client IP, so rate limits apply per client:

```elixir
config :my_app, MyApp.Auth, advanced: [ip_address_headers: ["x-forwarded-for"]]
```

Only do this behind a proxy that sets the header; otherwise clients can set
it and dodge rate limits. Proxies append to `x-forwarded-for`, so authmk reads
it from the right: the first public address it finds is the client's, and
private addresses (your own proxies) are skipped. If your clients reach you
over a private network, use a header your proxy overwrites instead, such as
`x-real-ip`.

## Several nodes

Rate limits are kept in memory by default, so each node counts separately.
To share them, and to keep sessions out of the database, use Redis or Valkey:

```elixir
children = [{Redix, {System.fetch_env!("REDIS_URL"), [name: MyApp.Redix]}}, MyApp.Repo, MyApp.Auth, ...]

config :my_app, MyApp.Auth,
  secondary_storage: {Authmk.Storage.Redis, conn: MyApp.Redix},
  rate_limit: [storage: :secondary_storage]
```

Or keep rate limits in the database with `Authmk.Plugins.DatabaseRateLimit`.

## Logs

authmk's log messages carry `domain: [:authmk]`, so standard Logger filters
can silence or route them. See `Authmk.Log`.
