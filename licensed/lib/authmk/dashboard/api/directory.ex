defmodule Authmk.Dashboard.API.Directory do
  @moduledoc false
  # The overview, SSO and SCIM, service accounts and the audit log.

  alias Authmk.Dashboard.{Data, Reply}
  alias Authmk.Dashboard.Data.Overview
  alias Authmk.Plugins.ServiceAccount

  def route(%Plug.Conn{method: "GET"} = conn, ["overview"], ctx, _admin),
    do: Reply.json(conn, 200, Overview.get(ctx))

  def route(%Plug.Conn{method: "GET"} = conn, ["sso"], ctx, _admin),
    do: Reply.json(conn, 200, Data.sso(ctx))

  def route(%Plug.Conn{method: "GET"} = conn, ["service-accounts"], ctx, _admin),
    do: Reply.page(conn, Data.service_accounts(ctx, Reply.offset(conn)), :service_accounts)

  def route(%Plug.Conn{method: "POST"} = conn, ["service-accounts", id, action], ctx, admin)
      when action in ~w(disable enable delete) do
    case Data.find_service_account(ctx, id) do
      nil -> Reply.not_found(conn, "service account")
      account -> service_account(conn, ctx, admin, account, action)
    end
  end

  def route(%Plug.Conn{method: "GET"} = conn, ["events"], ctx, _admin) do
    filters = [event: Reply.param(conn, "event"), user_id: Reply.param(conn, "user_id")]
    Reply.json(conn, 200, Data.events(ctx, filters, Reply.offset(conn)))
  end

  def route(conn, _path, _ctx, _admin), do: Reply.not_found(conn)

  defp service_account(conn, ctx, admin, account, "delete") do
    event = {"service_account.deleted", %{metadata: %{service_account_id: to_string(account.id)}}}

    Reply.permitted(conn, ctx, admin, %{service_account: [:delete]}, event, fn ->
      ServiceAccount.remove(ctx, account)
    end)
  end

  defp service_account(conn, ctx, admin, account, action) do
    event =
      {"service_account.#{action}d", %{metadata: %{service_account_id: to_string(account.id)}}}

    Reply.permitted(conn, ctx, admin, %{service_account: [:update]}, event, fn ->
      with {:ok, _account} <-
             Authmk.Store.update(ctx, :service_account, account, %{disabled: action == "disable"}),
           do: :ok
    end)
  end
end
