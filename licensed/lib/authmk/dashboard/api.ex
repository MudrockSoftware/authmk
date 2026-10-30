defmodule Authmk.Dashboard.API do
  @moduledoc false
  # The dashboard's JSON API, under `<mount>/api/`. Every request needs a
  # signed-in admin (the licence is checked before, in Authmk.Dashboard); changes
  # need a trusted Origin (CSRF) and the action's own Admin permission.

  import Plug.Conn

  alias Authmk.{Context, Origin, SessionStore, Store}
  alias Authmk.Dashboard.{Access, Data}
  alias Authmk.Plugins.{AuditLog, Organization, SCIM, ServiceAccount, SSO, TwoFactor}

  @doc "Handles `api/*`: `path` is what follows `api/`."
  def call(conn, path, opts) do
    conn = conn |> fetch_query_params() |> put_resp_header("cache-control", "no-store")

    case Access.admin(conn, opts) do
      {:ok, ctx, admin} -> from_dashboard(conn, ctx, admin, path)
      :signed_out -> error(conn, 401, "signed_out", "Sign in as an admin to use the dashboard.")
      :forbidden -> error(conn, 403, "forbidden", "Your account can't use the dashboard.")
    end
  end

  defp from_dashboard(conn, ctx, admin, path) do
    case same_origin(conn, ctx) do
      :ok ->
        route(conn, conn.method, path, ctx, admin)

      {:error, :origin} ->
        error(conn, 403, "invalid_origin", "Requests must come from the dashboard.")
    end
  end

  defp same_origin(%Plug.Conn{method: "GET"}, _ctx), do: :ok

  defp same_origin(conn, %Context{} = ctx) do
    if Origin.trusted_request?(%{ctx | conn: conn}), do: :ok, else: {:error, :origin}
  end

  defp route(conn, "GET", ["me"], ctx, admin), do: json(conn, 200, me(ctx, admin))
  defp route(conn, "GET", ["overview"], ctx, _admin), do: json(conn, 200, Data.overview(ctx))

  defp route(conn, "GET", ["users"], ctx, _admin) do
    page(conn, Data.users(ctx, conn.query_params["search"], offset(conn)), :users)
  end

  defp route(conn, "GET", ["users", id], ctx, _admin) do
    with_user(conn, ctx, id, fn user -> json(conn, 200, Data.user_detail(ctx, user)) end)
  end

  defp route(conn, "POST", ["users", id, action], ctx, admin)
       when action in ~w(ban unban revoke-sessions disable-two-factor) do
    with_user(conn, ctx, id, fn user -> act(conn, ctx, admin, user, action) end)
  end

  defp route(conn, "POST", ["users", id, "sessions", session_id, "revoke"], ctx, admin) do
    with_user(conn, ctx, id, fn user ->
      permitted(conn, ctx, admin, %{session: [:revoke]}, fn ->
        :ok = SessionStore.delete_by_id(ctx, user.id, session_id)
      end)
    end)
  end

  defp route(conn, "GET", ["organizations"], ctx, _admin),
    do: page(conn, Data.organizations(ctx, offset(conn)), :organizations)

  defp route(conn, "GET", ["organizations", id], ctx, _admin) do
    case Data.organization_detail(ctx, id) do
      nil -> error(conn, 404, "not_found", "No such organization.")
      detail -> json(conn, 200, detail)
    end
  end

  defp route(conn, "GET", ["sso"], ctx, _admin), do: json(conn, 200, Data.sso(ctx))

  defp route(conn, "GET", ["service-accounts"], ctx, _admin),
    do: page(conn, Data.service_accounts(ctx, offset(conn)), :service_accounts)

  defp route(conn, "POST", ["service-accounts", id, action], ctx, admin)
       when action in ~w(disable enable delete) do
    case Data.find_service_account(ctx, id) do
      nil -> error(conn, 404, "not_found", "No such service account.")
      account -> service_account_action(conn, ctx, admin, account, action)
    end
  end

  defp route(conn, "GET", ["events"], ctx, _admin) do
    filters = [
      event: blank(conn.query_params["event"]),
      user_id: blank(conn.query_params["user_id"])
    ]

    json(conn, 200, Data.events(ctx, filters, offset(conn)))
  end

  defp route(conn, _method, _path, _ctx, _admin),
    do: error(conn, 404, "not_found", "No such page.")

  defp act(conn, ctx, admin, user, "ban") do
    permitted(conn, ctx, admin, %{user: [:ban]}, fn ->
      {:ok, _user} =
        Store.update(ctx, :user, user, %{banned: true, ban_reason: "Banned from the dashboard"})

      :ok = SessionStore.delete_all(ctx, user.id)
    end)
  end

  defp act(conn, ctx, admin, user, "unban") do
    permitted(conn, ctx, admin, %{user: [:ban]}, fn ->
      {:ok, _user} =
        Store.update(ctx, :user, user, %{banned: false, ban_reason: nil, ban_expires: nil})
    end)
  end

  defp act(conn, ctx, admin, user, "revoke-sessions") do
    permitted(conn, ctx, admin, %{session: [:revoke]}, fn ->
      :ok = SessionStore.delete_all(ctx, user.id)
    end)
  end

  # For a user who lost their device: two-factor off, its secrets gone.
  defp act(conn, ctx, admin, user, "disable-two-factor") do
    permitted(conn, ctx, admin, %{user: [:update]}, fn ->
      _removed =
        if Data.model?(ctx, :two_factor), do: Store.delete_all(ctx, :two_factor, user_id: user.id)

      {:ok, _user} = Store.update(ctx, :user, user, %{two_factor_enabled: false})
    end)
  end

  defp service_account_action(conn, ctx, admin, account, "delete") do
    permitted(conn, ctx, admin, %{service_account: [:delete]}, fn ->
      :ok = ServiceAccount.remove(ctx, account)
    end)
  end

  defp service_account_action(conn, ctx, admin, account, action) do
    permitted(conn, ctx, admin, %{service_account: [:update]}, fn ->
      {:ok, _account} =
        Store.update(ctx, :service_account, account, %{disabled: action == "disable"})
    end)
  end

  defp permitted(conn, ctx, admin, permissions, fun) do
    if Access.can?(ctx, admin, permissions) do
      _done = fun.()
      json(conn, 200, %{ok: true})
    else
      error(conn, 403, "forbidden", "Your role doesn't allow this.")
    end
  end

  defp with_user(conn, ctx, id, fun) do
    case Data.find_user(ctx, id) do
      nil -> error(conn, 404, "not_found", "No such user.")
      user -> fun.(user)
    end
  end

  defp me(ctx, admin) do
    %{
      user: Data.user(admin),
      app_name: ctx.config.app_name,
      can: %{
        ban: Access.can?(ctx, admin, %{user: [:ban]}),
        revoke_sessions: Access.can?(ctx, admin, %{session: [:revoke]}),
        update_users: Access.can?(ctx, admin, %{user: [:update]}),
        manage_service_accounts: Access.can?(ctx, admin, %{service_account: [:update, :delete]})
      },
      features: %{
        organizations: Data.enabled?(ctx, Organization),
        audit_log: Data.enabled?(ctx, AuditLog),
        sso: Data.enabled?(ctx, SSO),
        scim: Data.enabled?(ctx, SCIM),
        two_factor: Data.enabled?(ctx, TwoFactor),
        service_accounts: Data.enabled?(ctx, ServiceAccount)
      }
    }
  end

  defp page(conn, rows, key) do
    size = Data.page_size()
    json(conn, 200, %{key => Enum.take(rows, size), :has_more => length(rows) > size})
  end

  defp offset(conn) do
    case Integer.parse(conn.query_params["offset"] || "0") do
      {offset, ""} when offset >= 0 -> min(offset, 100_000)
      _invalid -> 0
    end
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end

  defp error(conn, status, code, message),
    do: json(conn, status, %{error: %{code: code, message: message}})
end
