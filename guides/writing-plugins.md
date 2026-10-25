# Writing a plugin

A plugin is a module that implements `Authmk.Plugin`. Every callback is
optional, so a plugin can be as small as one hook. This guide builds a plugin
that lets users record which theme they prefer.

## 1. The module

```elixir
defmodule MyApp.Auth.ThemePlugin do
  use Authmk.Plugin

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, themes: [type: {:list, :string}, default: ["light", "dark"]])
end
```

Enable it in your auth module:

```elixir
use Authmk,
  plugins: [Authmk.Plugins.EmailPassword, {MyApp.Auth.ThemePlugin, themes: ["light", "dark", "dim"]}],
  ...
```

`init/1` runs when the auth module starts. Validate options there and raise
on mistakes, so a bad config fails at boot.

## 2. Schema

`schema/1` returns models and fields, in the same format as `use Authmk`'s
`schema:` option (see `Authmk.Schema.Field` for every field option):

```elixir
@impl true
def schema(_opts) do
  %{user: [fields: [theme: [type: :string, default: "light", input: false]]]}
end
```

Rules that keep plugins working on SQLite, PostgreSQL, MySQL and MariaDB:

  * Use only the portable types: `:string`, `:text`, `:integer`, `:boolean`,
    `:datetime`, `:map`.
  * Fields added to an existing table must be nullable or have a default.
  * `:text` and `:map` fields can't have a default.

Run `mix authmk.gen.migration` after enabling the plugin.

## 3. Endpoints

```elixir
@impl true
def endpoints(_opts) do
  [
    Authmk.Endpoint.new(
      name: :set_theme,
      method: :post,
      path: "/theme",
      handler: {__MODULE__, :set_theme},
      session: :required,
      params: [theme: [type: :string, required: true]],
      rate_limit: [window: 60, max: 10]
    )
  ]
end

def set_theme(ctx) do
  themes = Authmk.Context.plugin_opts(ctx, __MODULE__)[:themes]

  if ctx.params.theme in themes do
    with {:ok, user} <- Authmk.Store.update(ctx, :user, ctx.user, %{theme: ctx.params.theme}) do
      {:ok, %{theme: user.theme}, %{ctx | user: user}}
    end
  else
    {:error, Authmk.Error.custom(:unknown_theme, 422, "That theme doesn't exist")}
  end
end
```

Handlers receive an `Authmk.Context`: `ctx.params` (validated, atom keys),
`ctx.user` and `ctx.session` (when loaded), `ctx.config`. They return
`{:ok, body, ctx}`, `{:redirect, url, ctx}`, `{:html, status, html, ctx}` or
`{:error, %Authmk.Error{}}`.

Building blocks you can use from handlers:

| Module | For |
|---|---|
| `Authmk.Store` | Database reads and writes, with hooks and telemetry |
| `Authmk.Sessions` | Creating, loading and revoking sessions; `fresh?/1` |
| `Authmk.Verification` | Single-use tokens for email links |
| `Authmk.Credentials` | Checking and setting passwords |
| `Authmk.Crypto` | Signing and encrypting with the app's secret |
| `Authmk.Origin` | Checking redirect targets (`check_redirect/2`) |
| `Authmk.Background` | Running side work, like sending email |
| `Authmk.Error` | Errors, including `custom/4` for your own codes |

## 4. Hooks and middleware

Hooks run for every request, so match what you need and pass everything else
through:

```elixir
@impl true
def before_endpoint(:sign_up_email, ctx) do
  if ctx.raw_params["theme"] in [nil, "light", "dark"],
    do: {:cont, ctx},
    else: {:halt, Authmk.Error.new(:bad_request)}
end

def before_endpoint(_endpoint, ctx), do: {:cont, ctx}
```

| Callback | When |
|---|---|
| `on_request/1` | Before any built-in check; can stop the request |
| `before_endpoint/2` | After the session loads, before the handler |
| `after_endpoint/3` | After the handler; can change the result |
| `on_response/2` | Just before the response is sent; gets the `Plug.Conn` |
| `database_hook/4` | Around every insert, update and delete |

For a check that several of your own endpoints share, give those endpoints a
`middleware: [{module, function}]` list instead of a hook.

## 5. Tests

Test plugins the way authmk tests itself: define an auth module that enables
the plugin, give each test a new database, and send real requests. See
`test/support/emulation_case.ex` in the authmk repository for a template.
