defmodule Authmk.Dashboard do
  @moduledoc """
  An admin dashboard to run your app's auth. Mount it in any Plug or
  Phoenix router, outside pipelines that check CSRF tokens (it checks the
  Origin itself):

      # Phoenix
      forward "/admin/auth", Authmk.Dashboard, auth: MyApp.Auth

      # Plug.Router
      forward "/admin/auth", to: Authmk.Dashboard, init_opts: [auth: MyApp.Auth]

  It's a single-page app, built with SvelteKit and shipped ready-made in
  authmk's `priv/licensed/dashboard`, with a JSON API under `api/`. Each
  page shows only what your app has set up:

    * **Analytics**: active users, sign-ins and sign-ups by method, failed
      sign-ins, email verification and second-factor adoption, by date
      range and organization, and CSV exports of users, audit events and
      the daily figures. Sign-in history, methods and failures come from
      `Authmk.Plugins.AuditLog`.
    * **Users**: create, edit (with the fields your schema declares, editable
      where `input: true` allows), verify emails, set passwords and roles,
      ban, revoke sessions, unlink accounts, impersonate and delete
      (`Authmk.Plugins.Admin`). Each user's page shows what they can see
      and do, and where each permission comes from: their roles, in the app
      and in each organization and team, their sessions, linked accounts,
      API keys and second factors.
    * **Organizations** (`Authmk.Plugins.Organization`): create, edit and
      delete them, and manage members and their roles, teams and
      invitations, without being a member.
    * **Payments** (a payment plugin, see `Authmk.Payments`): recurring
      revenue from your plans' prices, new and cancelled subscriptions by
      plan and provider, and changing plans, cancelling and resuming
      through the provider.
    * **Integrations**: health checks of email and SMS senders, social and
      SSO providers (discovery, client credentials, certificate and secret
      expiry), SCIM, payment webhooks, secondary storage and background
      jobs, with warnings on the home page.
    * **Branding** (`Authmk.Dashboard.Branding`): the app's name, logo and
      colour, for the dashboard, authmk's pages and its emails.

  Every change made from the dashboard is written to the audit log as a
  `dashboard.*` event, with the admin as the actor (add
  `Authmk.Plugins.AuditLog`; the Integrations page warns without it).

  Options:

    * `:auth` - your auth module (required)
    * `:can_access` - `{module, function}` called with the user and the auth
      module, returning whether they may open it. Default:
      `Authmk.Plugins.Admin`'s admins (users who may list users). Each
      action checks its own Admin permission too (ban, revoke sessions...;
      `organization`, `subscription` and `branding` for those pages, see
      `Authmk.Plugins.Admin.Permissions`), runs through the same rules as
      the Admin and Organization plugins' endpoints, and changes no user
      stronger than the admin (`Authmk.Plugins.Admin.can_manage?/3`).

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
