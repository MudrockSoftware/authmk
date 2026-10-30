defmodule Authmk.Dashboard.API do
  @moduledoc false
  # The dashboard's JSON API, under `<mount>/api/`. Every request needs a
  # signed-in admin (the licence is checked before, in Authmk.Dashboard);
  # changes need a trusted Origin (CSRF) and the action's own Admin
  # permission, and are written to the audit log (Authmk.Dashboard.Audit).
  # Each area has its module; this one checks who's asking and routes.

  import Plug.Conn

  alias Authmk.{Context, Origin}
  alias Authmk.Dashboard.{Access, Data, Reply}

  alias Authmk.Dashboard.API.{
    Analytics,
    Branding,
    Directory,
    Health,
    Organizations,
    Payments,
    Users
  }

  alias Authmk.Plugins.{
    Admin,
    APIKey,
    AuditLog,
    Organization,
    Passkey,
    SCIM,
    ServiceAccount,
    SSO,
    TwoFactor
  }

  # Logos are the largest thing sent: a little over 512 KB as base64.
  @parsers Plug.Parsers.init(
             parsers: [:json],
             pass: ["*/*"],
             json_decoder: JSON,
             length: 1_000_000
           )

  @doc "Handles `api/*`: `path` is what follows `api/`."
  def call(conn, path, opts) do
    conn =
      conn
      |> fetch_cookies()
      |> fetch_query_params()
      |> put_resp_header("cache-control", "no-store")

    case Access.admin(conn, opts) do
      {:ok, ctx, admin} ->
        from_dashboard(conn, ctx, admin, path)

      :signed_out ->
        Reply.error(conn, 401, "signed_out", "Sign in as an admin to use the dashboard.")

      :forbidden ->
        Reply.error(conn, 403, "forbidden", "Your account can't use the dashboard.")
    end
  end

  defp from_dashboard(conn, ctx, admin, path) do
    with :ok <- same_origin(conn, ctx),
         {:ok, conn} <- parse_body(conn) do
      route(conn, path, %{ctx | conn: conn}, admin)
    else
      {:error, :origin} ->
        Reply.error(conn, 403, "invalid_origin", "Requests must come from the dashboard.")

      {:error, :body} ->
        Reply.error(conn, 400, "invalid_request", "The request couldn't be read.")
    end
  end

  defp same_origin(%Plug.Conn{method: "GET"}, _ctx), do: :ok

  defp same_origin(conn, %Context{} = ctx) do
    if Origin.trusted_request?(%{ctx | conn: conn}), do: :ok, else: {:error, :origin}
  end

  defp parse_body(%Plug.Conn{method: "GET"} = conn), do: {:ok, conn}

  defp parse_body(conn) do
    {:ok, Plug.Parsers.call(conn, @parsers)}
  rescue
    _unreadable -> {:error, :body}
  end

  defp route(conn, ["me"], ctx, admin), do: Reply.json(conn, 200, me(ctx, admin))
  defp route(conn, ["users" | path], ctx, admin), do: Users.route(conn, path, ctx, admin)

  defp route(conn, ["organizations" | path], ctx, admin),
    do: Organizations.route(conn, path, ctx, admin)

  defp route(conn, ["analytics" | path], ctx, admin), do: Analytics.route(conn, path, ctx, admin)
  defp route(conn, ["exports" | path], ctx, admin), do: Analytics.export(conn, path, ctx, admin)
  defp route(conn, ["payments" | path], ctx, admin), do: Payments.route(conn, path, ctx, admin)
  defp route(conn, ["health" | path], ctx, admin), do: Health.route(conn, path, ctx, admin)
  defp route(conn, ["branding" | path], ctx, admin), do: Branding.route(conn, path, ctx, admin)
  defp route(conn, path, ctx, admin), do: Directory.route(conn, path, ctx, admin)

  # The app's roles, to pick from when setting one.
  defp roles(ctx) do
    if Data.enabled?(ctx, Admin),
      do: Authmk.Context.plugin_opts(ctx, Admin)[:access_control].role_names(),
      else: []
  end

  defp me(ctx, admin) do
    can = &Access.can?(ctx, admin, &1)

    %{
      user: Data.user(admin),
      app_name: ctx.config.app_name,
      branding: Branding.public(ctx),
      roles: roles(ctx),
      can: %{
        create_users: can.(%{user: [:create]}),
        update_users: can.(%{user: [:update]}),
        set_roles: can.(%{user: [:set_role]}),
        set_passwords: can.(%{user: [:set_password]}),
        ban: can.(%{user: [:ban]}),
        impersonate: can.(%{user: [:impersonate]}),
        delete_users: can.(%{user: [:delete]}),
        revoke_sessions: can.(%{session: [:revoke]}),
        manage_service_accounts: can.(%{service_account: [:update, :delete]}),
        manage_organizations: can.(%{organization: [:create, :update, :delete]}),
        manage_subscriptions: can.(%{subscription: [:update]}),
        update_branding: can.(%{branding: [:update]})
      },
      features: %{
        admin: Data.enabled?(ctx, Admin),
        organizations: Data.enabled?(ctx, Organization),
        teams: Data.model?(ctx, :team),
        audit_log: Data.enabled?(ctx, AuditLog),
        sso: Data.enabled?(ctx, SSO),
        scim: Data.enabled?(ctx, SCIM),
        two_factor: Data.enabled?(ctx, TwoFactor),
        passkeys: Data.enabled?(ctx, Passkey),
        api_keys: Data.enabled?(ctx, APIKey),
        service_accounts: Data.enabled?(ctx, ServiceAccount),
        payments: Data.model?(ctx, :subscription),
        branding: Branding.enabled?(ctx)
      }
    }
  end
end
