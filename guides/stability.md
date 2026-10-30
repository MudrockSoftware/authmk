# Stability and upgrades

authmk follows [Semantic Versioning](https://semver.org) from 1.0. A
1.x release never breaks code written for an earlier 1.x, except to fix a
security problem (see below).

## What's covered

The public API is everything documented on HexDocs:

- **Modules and functions with docs.** Their names, arities, arguments
  and return shapes. Anything marked `@moduledoc false` or `@doc false`
  is internal and may change in any release, even when it's callable.
- **`use Authmk` options and plugin options.** Names, accepted values and
  defaults, as validated by their NimbleOptions schemas.
- **HTTP endpoints.** Paths, methods, request fields, response fields,
  status codes and cookie names.
- **Error codes.** Every code in the [error reference](errors.md), with
  its status.
- **Telemetry events and log metadata.** Event names, measurements and
  metadata keys.
- **The plugin API.** The behaviours plugins and adapters implement:
  `Authmk.Plugin`, `Authmk.OAuth.Provider`, `Authmk.Payments.Provider`,
  `Authmk.Storage`, `Authmk.SMS`, `Authmk.Password` and
  `Authmk.Plugins.JWT.KeyStore`, plus `Authmk.Context`, `Authmk.Endpoint`,
  `Authmk.Store` and the other modules their callbacks receive.
- **Mix tasks** and their flags.

## What may change in a minor release

These are additions, not breaks:

- New modules, functions, options, endpoints and error codes.
- New fields in responses. Clients should ignore fields they don't know.
- New optional callbacks in a behaviour. Existing plugins keep compiling.
- New tables or columns. They come with a migration: run
  `mix authmk.gen.migration` after upgrading (see [Upgrading](#upgrading)).
  Columns a release adds to an existing table are nullable or have a default.
- Error messages. Messages are English text for people and may be reworded
  at any time. Match on `code`.
- Log message text. Match on metadata, not on wording.
- Internal modules and functions.

## Security fixes come first

authmk protects other people's users. When the only safe fix for a
vulnerability changes behaviour, the fix ships in a patch release anyway,
and the release notes say what changed and why. For example, a release may
refuse input it used to accept, or tighten a default.

A safer default that isn't a security fix waits for the next major
version, or arrives as an option you turn on.

## Deprecations

Nothing public is removed in a minor release. Instead:

1. It's marked deprecated in a minor release, with the replacement. Functions
   get `@deprecated`, so the compiler warns. Options and endpoints log a
   warning once, when the auth module starts or the endpoint is first used.
2. The release notes list the deprecation.
3. `mix authmk.upgrade` rewrites your code to the replacement where it can.
4. It's removed in the next major version, at the earliest, and no sooner
   than six months after it was deprecated.

## Upgrading

```
mix igniter.upgrade authmk
```

Igniter updates the dependency, then runs `mix authmk.upgrade` with the old
and new versions. It applies the code changes each version needs, generates
the migration for any schema changes and lists what to check by hand.
Review the diff and the migration, then run `mix ecto.migrate`.

Without Igniter: update the version in `mix.exs`, run `mix deps.get`, read
the release notes, then run `mix authmk.gen.migration` and
`mix ecto.migrate`.

## Supported versions

- **Elixir** 1.20 and later, on the Erlang/OTP versions it supports.
- **Databases:** SQLite, PostgreSQL, MySQL and MariaDB through Ecto. The
  test suite runs on each of them for every change.
- **authmk releases:** security fixes go into the latest minor release of
  the current major version. See [SECURITY.md](https://github.com/MudrockSoftware/authmk/blob/main/SECURITY.md)
  to report a vulnerability.
