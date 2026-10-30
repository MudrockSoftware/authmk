defmodule Authmk.Dashboard do
  @moduledoc """
  An admin dashboard for your users, sessions, organizations, SSO and
  SCIM, audit log and sign-in analytics. Mount it in any Plug or Phoenix
  router, outside pipelines that check CSRF tokens (it checks the Origin
  itself):

      # Phoenix
      forward "/admin/auth", Authmk.Dashboard, auth: MyApp.Auth

      # Plug.Router
      forward "/admin/auth", to: Authmk.Dashboard, init_opts: [auth: MyApp.Auth]

  It's a single-page app, built with SvelteKit and shipped ready-made in
  authmk's `priv/licensed/dashboard`, with a JSON API under `api/`.

  Options:

    * `:auth` - your auth module (required)
    * `:can_access` - `{module, function}` called with the user and the auth
      module, returning whether they may open it. Default:
      `Authmk.Plugins.Admin`'s admins (users who may list users). Each
      action checks its own Admin permission too (ban, revoke sessions...).

  Signed-out users and others are sent to `/`.

  The dashboard is licensed separately from authmk (see `licensed/` and
  `Authmk.License`): outside development it needs `AUTHMK_LICENCE_KEY`.
  Without a valid key it answers every request, its page, files and API,
  with a 403, and logs why.
  """

  @behaviour Plug

  import Plug.Conn

  alias Authmk.Dashboard.{Access, API}
  alias Authmk.{License, Log}

  @headers [
    {"x-frame-options", "DENY"},
    {"content-security-policy", "frame-ancestors 'none'"},
    {"referrer-policy", "same-origin"},
    {"x-content-type-options", "nosniff"}
  ]

  @impl true
  def init(opts) do
    %{
      auth: Keyword.fetch!(opts, :auth),
      can_access: opts[:can_access],
      static:
        Plug.Static.init(
          at: "/",
          from: {:authmk, "priv/licensed/dashboard"},
          only: ["_app", "favicon.svg"]
        )
    }
  end

  @impl true
  def call(conn, opts) do
    conn = merge_resp_headers(conn, @headers)

    # Nothing of it, not even its files, without a valid licence.
    case License.check() do
      :ok -> route(conn, opts)
      {:error, reason} -> unlicensed(conn, reason)
    end
  end

  defp route(conn, opts) do
    case conn.path_info do
      ["api" | path] -> API.call(conn, path, opts)
      ["_app" | _rest] -> assets(conn, opts)
      ["favicon.svg"] -> assets(conn, opts)
      [] -> page(conn, opts)
      _unknown -> conn |> send_resp(404, "Not found") |> halt()
    end
  end

  # The app's shell. Relative asset links need the trailing slash.
  defp page(conn, opts) do
    cond do
      not String.ends_with?(conn.request_path, "/") ->
        conn
        |> put_resp_header("location", conn.request_path <> "/")
        |> send_resp(301, "")
        |> halt()

      match?({:ok, _ctx, _user}, Access.admin(conn, opts)) ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, index())
        |> halt()

      true ->
        conn |> put_resp_header("location", "/") |> send_resp(302, "") |> halt()
    end
  end

  defp unlicensed(conn, reason) do
    Log.error("authmk dashboard refused: " <> License.explain(reason))

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(403, "This dashboard needs a licence key.")
    |> halt()
  end

  defp assets(conn, opts) do
    case Plug.Static.call(conn, opts.static) do
      %Plug.Conn{halted: true} = conn -> conn
      conn -> conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp index,
    do:
      File.read!(Path.join(Application.app_dir(:authmk, "priv/licensed/dashboard"), "index.html"))
end
