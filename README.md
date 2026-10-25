# Authmk

Website: <https://authmk.com>

> **Status: early development.** The foundation and email/password
> authentication work and are tested; most plugins are still to come (see
> [ROADMAP.md](ROADMAP.md)). The API will change before 1.0.

## Why

Elixir has good building blocks for authentication: `phx.gen.auth`, Ueberauth,
Guardian, Assent, and Ash Authentication if you use Ash. What it doesn't have is
a framework where a plugin can add database tables, routes and lifecycle hooks
in one place, the way Better Auth does for TypeScript. Authmk aims to bring that
model to Phoenix and Ecto.

## Getting started

1. Add the dependency:

   ```elixir
   {:authmk, "~> 0.1.0"}
   ```

2. Define an auth module:

   ```elixir
   defmodule MyApp.Auth do
     use Authmk,
       otp_app: :my_app,
       repo: MyApp.Repo,
       plugins: [Authmk.Plugins.EmailPassword]

     @impl Authmk
     def send_reset_password(%{user: user, url: url}, _ctx) do
       MyApp.Mailer.deliver_reset_link(user.email, url)
     end
   end
   ```

3. Set a secret, configure, start it after your repo, and mount it:

   ```sh
   mix authmk.gen.secret            # put the output in AUTHMK_SECRET
   ```

   ```elixir
   # config/runtime.exs
   config :my_app, MyApp.Auth, base_url: "https://example.com"

   # application.ex
   children = [MyApp.Repo, MyApp.Auth, ...]

   # router.ex (Phoenix or Plug.Router)
   forward "/auth", MyApp.Auth
   ```

4. Generate and run the migration:

   ```sh
   mix authmk.gen.migration
   mix ecto.migrate
   ```

5. Load the signed-in user in your own pipelines:

   ```elixir
   plug Authmk.Plug.FetchSession, auth: MyApp.Auth   # assigns :current_user, :current_session
   plug Authmk.Plug.RequireAuthenticated, redirect_to: "/sign-in"
   ```

Clients then call `POST /auth/sign-up/email`, `POST /auth/sign-in/email`,
`GET /auth/get-session` and so on. See `Authmk.Endpoints` and
`Authmk.Plugins.EmailPassword` for every endpoint. Working Plug and Phoenix
apps are in [`examples/`](https://github.com/MudrockSoftware/authmk/tree/main/examples).

## Design

### Plugins

A plugin is a module that implements the `Authmk.Plugin` behaviour. It can contribute:

- **Schema**: new tables, or extra fields on core tables such as `user`
- **Endpoints**: served under the auth router
- **Hooks**: `before_endpoint/2`, which can stop a request, `after_endpoint/3`,
  which can change the result, and `database_hook/4` around every write
- **Options**: validated in `init/1`

```elixir
defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    plugins: [
      {Authmk.Plugins.EmailPassword, require_email_verification: true},
      MyApp.Auth.AuditPlugin
    ]

  # Your auth module gets the same hooks as plugins.
  @impl Authmk
  def before_endpoint(:sign_up_email, ctx) do
    if String.ends_with?(ctx.raw_params["email"], "@example.com"),
      do: {:cont, ctx},
      else: {:halt, Authmk.Error.new(:forbidden)}
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}
end
```

### Schema declared in config

As in Better Auth, the schema is declared in config. Core models, plugin
models and your own settings are merged at compile time into one resolved
schema. That schema drives the Ecto schemas, input validation and migrations.

```elixir
use Authmk,
  repo: MyApp.Repo,
  table_naming: :plural,          # :plural (default) | :singular
  table_prefix: "auth_",          # optional
  schema: [
    user: [
      module: MyApp.Accounts.User,
      table: "users",             # an explicit table name always wins
      fields: [name: [source: :full_name]],
      additional_fields: [
        role: [type: :string, default: "user", input: false]
      ]
    ]
  ]
```

- **Table names:** an explicit `table:` wins; otherwise `table_prefix` plus the
  singular or plural model name.
- **References:** these point at models, not tables, so renaming a table
  updates every foreign key.
- **Existing databases:** you can map authmk onto tables you already have, such
  as `users` from `phx.gen.auth`, including renamed columns.

Models the library owns (sessions, accounts, verifications and so on) are
generated for you. Models you own, like the user, keep your own module and
pull in authmk's fields with a macro:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  use Authmk.Schema, auth: MyApp.Auth, model: :user

  schema "users" do
    authmk_fields()
    has_many :posts, MyApp.Blog.Post
    timestamps()
  end
end
```

### Migrations

Migrations are generated from the resolved schema. Authmk compares it with a
snapshot committed to your repo, similar to drizzle-kit, and writes normal
Ecto migrations:

```sh
mix authmk.gen.migration              # write a migration for schema changes
mix authmk.gen.migration --baseline   # record existing tables, write nothing
mix authmk.gen.migration --check      # fail in CI if a migration is missing
mix ecto.migrate
```

Destructive changes such as drops need `--allow-destructive`. Interactive
rename detection is planned.

### Databases

SQLite, PostgreSQL, MySQL and MariaDB are all supported through Ecto. Authmk follows
whichever adapter your repo uses, and there is no default.

To stay compatible with all of them, the schema only uses features they all
share. That means no array columns, no `citext`, no partial indexes, no
defaults computed by the database, and no defaults on `:text` or `:map` fields
(MySQL rejects them). IDs are generated by the app, emails are
normalized in code, and any field a plugin adds to an existing table must be
nullable or have a default, because SQLite can't change an existing column.

### Validation

Input is validated with Ecto changesets built from the field specs. That
means validation errors work with Phoenix forms (`to_form/1`) without any
adapter code.

### Language

Authmk is English only. Errors carry a stable `code`, such as
`:invalid_credentials`, so apps can show their own text if they want.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full feature plan toward 1.0.

## Installation

```elixir
def deps do
  [
    {:authmk, "~> 0.1.0"}
  ]
end
```

Documentation: <https://hexdocs.pm/authmk>

## Acknowledgements

Authmk's design borrows heavily from [Better Auth](https://github.com/better-auth/better-auth):
its plugin model, schema-in-config approach and CLI-driven schema generation.
Authmk is an independent project and is not affiliated with Better Auth.

## License

MIT © Mudrock Software LTD. See [LICENSE](https://github.com/MudrockSoftware/authmk/blob/main/LICENSE).
