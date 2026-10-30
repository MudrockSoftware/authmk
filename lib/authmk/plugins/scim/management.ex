defmodule Authmk.Plugins.SCIM.Management do
  @moduledoc false
  # Managing an organization's connections, with the app's `can_manage`.

  import Ecto.Query

  alias Authmk.{Context, SessionStore, Store}
  alias Authmk.Plugins.SCIM.Connections

  def create(%Context{params: params, user: user} = ctx) do
    with :ok <- Connections.allowed(ctx, :create, params.organization_id),
         {:ok, connection, token} <-
           Connections.create(ctx, %{
             organization_id: params.organization_id,
             provider_id: params.provider_id,
             name: params.name,
             user_id: user.id
           }) do
      {:ok, Map.put(Connections.to_public(connection), :token, token), ctx}
    end
  end

  def list(%Context{params: params} = ctx) do
    with :ok <- Connections.allowed(ctx, :read, params.organization_id) do
      module = Store.module(ctx, :scim_connection)

      connections =
        Store.list(
          ctx,
          :scim_connection,
          from(c in module, where: c.organization_id == ^params.organization_id)
        )

      {:ok, Enum.map(connections, &Connections.to_public/1), ctx}
    end
  end

  def rotate(%Context{params: params} = ctx) do
    with {:ok, connection} <- Connections.managed(ctx, params.connection_id, :rotate),
         {:ok, connection, token} <- Connections.rotate(ctx, connection) do
      {:ok, Map.put(Connections.to_public(connection), :token, token), ctx}
    end
  end

  # The token stops working, and the people it provisioned can't sign in.
  def decommission(%Context{params: params} = ctx) do
    with {:ok, connection} <- Connections.managed(ctx, params.connection_id, :decommission),
         {:ok, connection} <- Connections.decommission(ctx, connection) do
      links =
        Store.list(
          ctx,
          :scim_user,
          from(l in Store.module(ctx, :scim_user), where: l.scim_connection_id == ^connection.id)
        )

      _count =
        Store.update_all(
          ctx,
          :scim_user,
          from(l in Store.module(ctx, :scim_user), where: l.scim_connection_id == ^connection.id),
          set: [active: false]
        )

      Enum.each(links, &(:ok = SessionStore.delete_all(ctx, &1.user_id)))
      {:ok, Connections.to_public(connection), ctx}
    end
  end
end
