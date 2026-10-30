defmodule PlugApp.Router do
  @moduledoc """
  A plain Plug app (no Phoenix) that uses authmk.
  """

  use Plug.Router

  plug :well_known
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON
  plug :dispatch

  forward "/auth", to: PlugApp.Auth

  # authmk's admin dashboard, for users Authmk.Plugins.Admin calls admins.
  # Licensed separately: in production it needs AUTHMK_LICENCE_KEY.
  forward "/admin/auth", to: Authmk.Dashboard, init_opts: [auth: PlugApp.Auth]

  get "/" do
    send_resp(conn, 200, "ok")
  end

  # What a sign-in page needs: the method this browser used last.
  get "/sign-in" do
    last_used = Authmk.Plugins.LastSignInMethod.get(conn, PlugApp.Auth)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{last_used: last_used}))
  end

  # A sign-in page without JavaScript: the form posts straight to authmk,
  # which redirects back (authmk_redirect, and ?error= when it fails).
  get "/sign-in-form" do
    code = fetch_query_params(conn).query_params["error"]
    error = code && (Authmk.Error.message_for(code) || "Something went wrong.")

    html = """
    <!doctype html>
    <form method="post" action="/auth/sign-in/email">
      <input type="hidden" name="authmk_redirect" value="/me">
      #{if error, do: "<p role=\"alert\">#{Plug.HTML.html_escape(error)}</p>"}
      <input type="email" name="email" required>
      <input type="password" name="password" required>
      <button>Sign in</button>
    </form>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # Only for signed-in users (not service accounts).
  get "/me" do
    conn = guard(conn, Authmk.Plug.RequireUser, [])

    if conn.halted do
      conn
    else
      user = Authmk.Phoenix.Controller.current_user(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{email: user.email, name: user.name}))
    end
  end

  # Only for admins (Authmk.Plugins.Admin's role).
  get "/admin" do
    conn = guard(conn, Authmk.Plug.RequireRole, roles: ["admin"])
    if conn.halted, do: conn, else: send_resp(conn, 200, "admins only")
  end

  # Signs out from the app's own code.
  post "/sign-out" do
    conn
    |> Authmk.Plug.FetchSession.call(PlugApp.Auth)
    |> Authmk.Phoenix.Controller.sign_out(PlugApp.Auth)
    |> put_resp_header("location", "/")
    |> send_resp(303, "")
  end

  defp guard(conn, plug, opts) do
    conn
    |> Authmk.Plug.FetchSession.call(PlugApp.Auth)
    |> plug.call(plug.init(opts))
  end

  # For programs too: a service account's API key gets in.
  get "/whoami" do
    conn =
      conn
      |> Authmk.Plug.FetchSession.call(PlugApp.Auth)
      |> Authmk.Plug.RequireAuthenticated.call(
        Authmk.Plug.RequireAuthenticated.init(allow_principals: true)
      )

    if conn.halted do
      conn
    else
      body =
        case conn.assigns do
          %{current_user: %{} = user} ->
            %{type: "user", name: user.name}

          %{current_principal: service_account} ->
            %{type: "service_account", name: service_account.name}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
    end
  end

  # An API for other apps, with access tokens from the OAuth provider.
  get "/api/profile" do
    conn =
      Authmk.Plug.RequireAccessToken.call(
        conn,
        Authmk.Plug.RequireAccessToken.init(auth: PlugApp.Auth, scopes: ["profile"])
      )

    if conn.halted do
      conn
    else
      # A user's token, or a service account's (client credentials): both have a name.
      body = JSON.encode!(%{name: conn.assigns.current_principal.name})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  # The MCP server: tools for MCP clients holding a token for it.
  get "/mcp" do
    opts =
      Authmk.Plug.RequireAccessToken.init(
        auth: PlugApp.Auth,
        resource: PlugApp.Auth.mcp_url(),
        resource_metadata: resource_metadata_url()
      )

    conn = Authmk.Plug.RequireAccessToken.call(conn, opts)

    if conn.halted do
      conn
    else
      body = JSON.encode!(%{tools: [], user: conn.assigns.current_user.email})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Discovery for OAuth and MCP clients, at the root where they look.
  defp well_known(conn, _opts) do
    resources = [
      [resource: PlugApp.Auth.mcp_url(), scopes: ["openid", "profile"], name: "PlugApp tools"]
    ]

    Authmk.Plug.WellKnown.call(
      conn,
      Authmk.Plug.WellKnown.init(auth: PlugApp.Auth, protected_resources: resources)
    )
  end

  defp resource_metadata_url do
    Application.fetch_env!(:plug_app, PlugApp.Auth)[:base_url] <>
      "/.well-known/oauth-protected-resource/mcp"
  end
end
