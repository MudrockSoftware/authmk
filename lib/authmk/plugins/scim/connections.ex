defmodule Authmk.Plugins.SCIM.Connections do
  @moduledoc false
  # A connection is one identity provider provisioning one organization,
  # with its own bearer token (stored hashed). Everything it provisions is
  # its own: it never sees another connection's users or groups.

  alias Authmk.{Context, Error, Store, Token}
  alias Authmk.Plugins.SCIM.Config

  @prefix "scim_"

  @doc "A new connection, and its token, shown only now."
  def create(ctx, attrs) do
    token = @prefix <> Token.generate(32)

    record = %{
      organization_id: attrs[:organization_id],
      provider_id: attrs[:provider_id],
      name: attrs[:name],
      user_id: attrs[:user_id],
      token: Token.hash(token),
      status: "active"
    }

    with {:ok, connection} <- Store.insert(ctx, :scim_connection, record),
         do: {:ok, connection, token}
  end

  @doc "A new token; the old one stops working at once."
  def rotate(ctx, connection) do
    token = @prefix <> Token.generate(32)

    with {:ok, connection} <-
           Store.update(ctx, :scim_connection, connection, %{token: Token.hash(token)}),
         do: {:ok, connection, token}
  end

  @doc "Ends a connection: its token stops working, and its users are deactivated."
  def decommission(ctx, connection) do
    Store.update(ctx, :scim_connection, connection, %{
      status: "decommissioned",
      token: Token.hash(Token.generate(32))
    })
  end

  @doc "The connection whose token the request carries."
  def authenticate(%Context{conn: conn} = ctx) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         %{status: "active"} = connection <-
           Store.get_by(ctx, :scim_connection, token: Token.hash(String.trim(token))) do
      {:ok, connection}
    else
      _invalid -> :error
    end
  end

  @doc "A connection the signed-in user may act on."
  def managed(ctx, id, action) do
    case Store.get_by(ctx, :scim_connection, id: id) do
      nil ->
        {:error, not_found()}

      connection ->
        with :ok <- allowed(ctx, action, connection.organization_id), do: {:ok, connection}
    end
  rescue
    Ecto.Query.CastError -> {:error, not_found()}
  end

  @doc "Whether the signed-in user may act on an organization's connections."
  def allowed(ctx, action, organization_id) do
    case Config.opts(ctx)[:can_manage] do
      nil ->
        {:error, Error.new(:forbidden)}

      can? ->
        if can?.(action, organization_id, ctx) == true,
          do: :ok,
          else: {:error, Error.new(:forbidden)}
    end
  end

  @doc "What the management endpoints show. Never the token."
  def to_public(connection) do
    %{
      id: to_string(connection.id),
      organization_id: connection.organization_id,
      provider_id: connection.provider_id,
      name: connection.name,
      status: connection.status,
      created_at: connection.inserted_at
    }
  end

  defp not_found, do: Error.custom(:scim_connection_not_found, 404, "No such connection")
end
