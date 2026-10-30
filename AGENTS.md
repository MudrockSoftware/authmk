# authmk Development Guide

authmk is an extensible, plugin-based authentication framework for Elixir,
published by Mudrock Software LTD. Website: https://authmk.com.
Source: https://github.com/MudrockSoftware/authmk.

The full feature plan is in `ROADMAP.md`. Tick items there only when they are
implemented **and** covered by tests.

## Priorities

1. **Security and stability come first.** authmk protects other people's
   users. Choose the safe default, the well-tested path and the predictable
   behavior, even when that is slower or more code.
2. **Performance comes second.** Optimize only when it gives up nothing
   from (1), and back it with a measurement.

When these conflict, (1) wins. Examples: hash tokens even though plain lookups
are faster; keep a database round trip instead of caching something that
could go stale after a session is revoked; fail closed when a check can't be
completed.

## Project Structure

- `lib/`: the library (MIT)
- `licensed/`: features under Mudrock's commercial licence, not MIT: the admin
  dashboard and its analytics (`licensed/lib`, tests in `licensed/test`). They
  need `AUTHMK_LICENCE_KEY` outside development (`Authmk.License`). Keep
  licensed code here, and keep `lib/` free of dependencies on it. The
  dashboard's UI is a SvelteKit app in `licensed/dashboard` (bun); after
  changing it, run `bun run check` there. Follow Mudrock's design guide (colours,
  British English, sentence case).
- `assets/pages`: the user-facing pages authmk serves itself (the sign-in
  error page), a SvelteKit app (bun, MIT). After changing it, run
  `bun run check` there. Its theme in `src/app.css` copies the dashboard's: change
  both together.
- `priv/pages` and `priv/licensed`: built from those two apps by `mix compile`
  (a compiler in `mix.exs` runs bun when their sources change). Not in git;
  the Hex package ships them, and `licensed/lib`, without the app sources.
  Building from a checkout needs bun (`mise.toml`).
- `test/`: emulation tests for the library (see Testing)
- `examples/plug_app`: a plain Plug + Bandit + Ecto (SQLite) app that uses authmk
- `examples/phoenix_app`: a Phoenix 1.8 + LiveView + Ecto (SQLite) app that uses authmk.
  Its own `AGENTS.md` applies to code inside that directory.
- `ROADMAP.md`: feature plan after 1.0

## Commands

- First time: `mix setup` (fetches deps and enables the `.githooks/pre-commit` hook)
- Build: `mix build` rebuilds the pages and the dashboard into `priv/` with bun,
  stale or not, then compiles. `mix compile` rebuilds them only when their sources changed.
- Library tests: `mix test`; single file or line: `mix test test/path_test.exs:42`
- On a development machine, test with SQLite only (`mix test`) unless told
  otherwise. Running every database takes a lot of time for a simple schema
  change; CI runs them all.
- Other databases and Redis, when asked: start them with `docker compose up -d postgres mysql mariadb valkey redis`
  (see `compose.yml`), then `AUTHMK_TEST_DB=postgres mix test`, `AUTHMK_TEST_DB=mysql mix test`,
  `AUTHMK_TEST_DB=mariadb mix test`. Each database gets its own build directory.
  Code must still work on all four (see Architecture Decisions).
- Redis tests, when asked: `REDIS_URL=redis://localhost:6379 mix test` (Valkey) and
  `REDIS_URL=redis://localhost:6380 mix test --only redis` (Redis 8).
- Coverage: `mix coverage`. It fails below the `test_coverage` threshold (90%) and writes HTML to `cover/`.
- Fuzz tests: `mix fuzz` runs only `test/fuzz/` (StreamData properties tagged `:fuzz`),
  `FUZZ_RUNS` times each (default 1000). `mix test` excludes them.
- Lint: `mix lint` runs format, `compile --warnings-as-errors`, `credo --strict`,
  an xref compile-cycle check (zero allowed) and Dialyzer. The pre-commit hook runs it.
- Example app tests: `cd examples/plug_app && mix test`, `cd examples/phoenix_app && mix test`
- Secrets: tests read `AUTHMK_SECRET`, which `test/test_helper.exs` sets.
- Before finishing: `mix lint` and `mix coverage` must pass in the root, and
  `mix format` plus `mix test` must pass in every example app you touched.
- Parsers and decoders for untrusted input (tokens, cookies, JWTs, SAML, SCIM
  filters, OAuth params) get fuzz tests in `test/fuzz/`.

## Architecture Decisions

These are settled. Don't revisit them unless the user asks.

- **Ecto only.** No database adapter layer; the user passes their `repo:`.
- **SQLite, PostgreSQL, MySQL and MariaDB**, with no default; the adapter is detected from the
  repo. Schemas use only features all three share: no array columns, no `citext`,
  no partial indexes, no defaults computed by the database, no defaults on `:text` or `:map` fields, no `FOR UPDATE`, no
  `on_conflict` with `conflict_target`. Fields a plugin adds to an existing table
  must be nullable or have a default, because SQLite can't modify existing columns.
- **Schema declared in config.** Core models, plugin schemas and user config are
  merged at compile time into one resolved schema. Ecto schemas, changesets and
  migrations are all derived from it.
- **Table naming:** `table_naming: :plural | :singular` (plural is the default),
  `table_prefix`, and an explicit per-model `table:` that always wins. References
  point at model keys, never at table names.
- **Migrations** are generated by comparing a committed snapshot with the
  resolved schema (`mix authmk.gen.migration`).
- **Validation** uses Ecto changesets, including schemaless changesets for
  endpoint params. NimbleOptions validates config.
- **English only.** No translations. Errors are `%Authmk.Error{code:, message:}`
  with stable codes. Never lowercase emails with locale-aware casing.
- **Service accounts** are a separate model, not a flag on users.
- **Plugins** should be as independent as possible. When working on a plugin,
  prefer changing the plugin over changing core.

## Writing Code

Code must be well written, small and readable by a human who is debugging
it, possibly during an incident:

- Prefer the obvious solution over the clever one. Code that someone can
  read and trust is part of security.
- Keep functions and modules small, with one job each. Split a function when
  it needs a comment to explain its sections.
- Use clear names over abbreviations. Pattern-match and use `with` so the
  happy path and each failure path are easy to see.
- Make control flow explicit: no hidden side effects, no logic hidden in
  macros or process dictionaries.
- Return errors with enough context (`%Authmk.Error{code:, message:}`) to see
  what failed and why, without leaking secrets.
- Don't add abstractions, options or dependencies until a real need exists.
- When something is needed, use what Erlang/OTP ships first (for example
  `xmerl` for XML, `public_key` and `crypto` for certificates and
  signatures). Only when OTP lacks it, look for an Elixir library, then for
  a popular, maintained one on hex.pm, and check it for open advisories.
- Delete dead code instead of leaving it commented out.

General rules:

- Target Elixir `~> 1.20`. Follow `mix format`.
- Keep macros thin: `use Authmk` validates config and builds a registry; the
  logic lives in plain functions.
- Public modules and functions get `@moduledoc`, `@doc` and `@spec`. Internal
  modules get `@moduledoc false`.
- Security defaults:
  - Compare secrets with `Plug.Crypto.secure_compare/2`.
  - Store tokens and OTPs hashed.
  - Never log secrets, tokens or passwords.
  - Outbound HTTP must not follow redirects.
  - Generic errors must not reveal whether an email or user exists.

## Testing

**Every feature and every bug fix must ship with tests.** A feature isn't done
until it is tested in the library *and* exercised in both example apps.

### Emulation tests (library, `test/`)

Tests here emulate real usage. They are not unit tests.

- **One new SQLite database per test.** Each test creates a uniquely named
  SQLite file in a temp directory, runs authmk's generated migrations against
  it, and deletes it afterwards. Tests never share a database, so they can all
  run with `async: true`. Don't use the Ecto SQL sandbox for library tests.
- **Configure authmk the way a user would**: define an auth module in the test
  with `use Authmk`, its plugins and its options, backed by that test's repo.
- **Go through public entry points only**: HTTP requests against the auth
  router (`Plug.Test`), and the documented public API. Check what a user could
  observe: status codes, response bodies, cookies, rows in the database, emails
  and SMS messages sent, telemetry events.
- **Write full flows, not single functions.** For example: sign up → receive
  the verification email → verify → sign in → refresh the session → sign out.
- **Don't mock authmk internals.** Replace only external systems: OAuth and
  OIDC providers, SAML IdPs, HTTP APIs (with local fake servers, such as Bypass
  or a Plug started in the test), email (`Swoosh.Adapters.Test`) and SMS
  (a test sender).
- **Cover failure and security paths**: wrong credentials, expired and reused
  tokens, rate limits, CSRF and origin checks, and email-enumeration
  resistance.
- **Regression tests** link to the issue they cover with a comment above the
  test.
- Database portability: the same suite runs on PostgreSQL and MySQL
  (`AUTHMK_TEST_DB`). SQLite is the default. Tag tests that only make sense
  on one kind of database with `:sqlite` or `:server_database`.

### Example apps (`examples/`): the second test ground

- Both apps depend on authmk via `{:authmk, path: "../.."}` and must always
  compile and pass their tests against the current library code.
- Every user-facing feature gets wired into **both** example apps, the way a
  real user would integrate it (config, router, migrations, plugs, and in the
  Phoenix app LiveViews and components), with tests:
  - `examples/plug_app`: `Plug.Test` against `PlugApp.Router`
  - `examples/phoenix_app`: `Phoenix.ConnTest` and `Phoenix.LiveViewTest`
- Example apps use SQLite and are set up only through authmk's own mix tasks
  (`mix authmk.install`, `mix authmk.gen.migration`). If setup needs a manual
  step, that's a bug in authmk or its docs.
- The example apps double as documentation. Keep them idiomatic and minimal.

## Workflow

- Git history belongs to the developer. Agents may only use git to inspect
  code and to compare behavior while testing or fixing bugs:
  - Allowed: `git status`, `git log`, `git diff`, `git show`, `git blame`,
    `git stash` and `git stash pop`. Always pop what you stashed, so the
    working tree ends exactly as you found it.
  - Never: `commit` (including `--amend`), `push`, `pull`, `fetch`, `merge`,
    `rebase`, `cherry-pick`, `reset`, `checkout`, `switch` or `restore` on
    files, `clean`, `stash drop`/`clear`, creating or deleting branches or
    tags, or changing git config. Anything that writes history, touches a
    remote or can discard changes is the developer's job.
- Update `README.md`, the module docs and `ROADMAP.md` when you change
  public behavior.
