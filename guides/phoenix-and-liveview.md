# Phoenix and LiveView

authmk runs as a Plug: its endpoints are mounted in your router, and a few
plugs, hooks and components connect them to your pages.

## Router

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import Authmk.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Assigns :current_user, :current_session and :current_principal.
    plug Authmk.Plug.FetchSession, auth: MyApp.Auth
  end

  # Outside :browser: authmk checks the Origin of every change itself,
  # and HTML forms posting to it carry no CSRF token.
  scope "/" do
    authmk_routes "/auth", MyApp.Auth
  end

  scope "/", MyAppWeb do
    pipe_through :browser

    authmk_live_session :signed_out, MyApp.Auth, require: :signed_out, redirect_to: "/" do
      live "/sign-in", SignInLive
      live "/sign-up", SignUpLive
    end

    authmk_live_session :signed_in, MyApp.Auth, require: :user, redirect_to: "/sign-in" do
      live "/settings", SettingsLive
    end
  end

  scope "/admin", MyAppWeb do
    pipe_through [:browser, :admins]
    get "/reports", ReportController, :index
  end

  pipeline :admins do
    plug Authmk.Plug.RequireRole, roles: ["admin"], redirect_to: "/"
  end
end
```

`authmk_routes/2` is `forward`; `authmk_live_session/4` is `live_session`
with authmk's session data and `on_mount` hook (see `Authmk.LiveView`).

## Plugs

| Plug | Lets through |
|---|---|
| `Authmk.Plug.FetchSession` | everyone; assigns the session |
| `Authmk.Plug.RequireUser` | signed-in users |
| `Authmk.Plug.RequireAuthenticated, allow_principals: true` | users and service accounts (API keys) |
| `Authmk.Plug.RequireRole, roles: [...]` | users with one of the roles |
| `Authmk.Plug.RequireRole, auth: ..., permissions: %{...}` | users `Authmk.Plugins.Admin` allows |
| `Authmk.Plug.RequireAccessToken` | OAuth access tokens from `Authmk.Plugins.OAuthProvider` |

Each answers JSON (401 or 403), or redirects with `redirect_to:`.

## Controllers

```elixir
import Authmk.Phoenix.Controller

def show(conn, _params), do: render(conn, :show, user: current_user(conn))

def delete(conn, _params), do: conn |> sign_out(MyApp.Auth) |> redirect(to: ~p"/")
```

`sign_in/4` signs a user in from your own code, with the same rules as
authmk's sign-ins (it returns `{:challenge, conn, body}` when a second
factor is due).

## LiveView

LiveViews in an `authmk_live_session` get `@current_user`,
`@current_session` and `@current_principal`. LiveViews can't read cookies,
so the page hands them the session token's hash (never the token) in
LiveView's signed session data, and each mount, including every reconnect,
reads the session from the store: a revoked session stops working on the
next mount. To end a revoked session's open LiveViews at once:

```elixir
MyAppWeb.Endpoint.broadcast(Authmk.LiveView.socket_id(session), "disconnect", %{})
```

## Components

`Authmk.Components` and `Authmk.Components.Account` are plain HTML forms
posting to authmk's endpoints, so they work in dead views and LiveViews,
without JavaScript, and set cookies the normal way.

```heex
<.sign_in_form redirect_to={~p"/"} two_factor_redirect_to={~p"/two-factor"} error={@error} />
<.passkey_button redirect_to={~p"/"} />
```

```elixir
def mount(params, _session, socket), do: {:ok, assign(socket, error: params["error"])}
```

After a post, the browser goes to `redirect_to`, or comes back to the form's
page with `?error=<code>`; pass the code to the component as `error`.
Targets must be relative paths or trusted origins, checked before anything
runs.

The passkey button needs one script, in the root layout's `<head>`:

```heex
<Authmk.Components.passkey_script />
```

Every component takes `class`, and the forms `input_class` and
`button_class` (daisyUI's names by default), so they fit your design.

## Tests

`Authmk.Testing.sign_in/4` signs a test conn in, for controllers and
LiveViews alike:

```elixir
test "settings show the user", %{conn: conn} do
  user = Authmk.Testing.create_user(MyApp.Auth, email: "ada@example.com")
  {:ok, _view, html} = conn |> Authmk.Testing.sign_in(MyApp.Auth, user) |> live(~p"/settings")
  assert html =~ "ada@example.com"
end
```
