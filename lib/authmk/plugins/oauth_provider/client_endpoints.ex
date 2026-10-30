defmodule Authmk.Plugins.OAuthProvider.ClientEndpoints do
  @moduledoc false
  # Managing clients: the signed-in user's own (or what the app's
  # `client_privileges` allows), dynamic registration (RFC 7591), and the
  # public details a consent page shows.

  import Ecto.Query

  alias Authmk.{Context, Error, Origin, Store}
  alias Authmk.Plugins.OAuthProvider.{Clients, Config, Errors}

  def create(%Context{raw_params: params, user: user} = ctx) do
    with :ok <- allowed(ctx, :create),
         {:ok, client, secret} <-
           Clients.create(ctx, metadata(params), %{user_id: user.id, reference_id: reference(ctx)}) do
      {:ok, Clients.to_metadata(client, secret), Errors.no_store(ctx)}
    end
    |> to_error()
  end

  def get(%Context{params: params} = ctx) do
    with {:ok, client} <- owned(ctx, params.client_id, :read),
         do: {:ok, Clients.to_metadata(client), ctx}
  end

  def list(%Context{user: user} = ctx) do
    with :ok <- allowed(ctx, :read) do
      module = Store.module(ctx, :oauth_client)

      query =
        case reference(ctx) do
          nil ->
            from(c in module, where: c.user_id == ^user.id)

          reference ->
            from(c in module, where: c.user_id == ^user.id or c.reference_id == ^reference)
        end

      clients = Store.list(ctx, :oauth_client, query)
      {:ok, Enum.map(clients, &Clients.to_metadata/1), ctx}
    end
  end

  def update(%Context{params: params} = ctx) do
    with {:ok, client} <- owned(ctx, params.client_id, :update),
         {:ok, client} <- Clients.update(ctx, client, metadata(params.update)) do
      {:ok, Clients.to_metadata(client), ctx}
    end
    |> to_error()
  end

  def delete(%Context{params: params} = ctx) do
    with {:ok, client} <- owned(ctx, params.client_id, :delete),
         :ok <- Clients.forget(ctx, client),
         {:ok, _client} <- Store.delete(ctx, :oauth_client, client) do
      {:ok, %{success: true}, ctx}
    end
  end

  def rotate_secret(%Context{params: params} = ctx) do
    with {:ok, client} <- owned(ctx, params.client_id, :rotate),
         {:ok, client, secret} <- Clients.rotate_secret(ctx, client) do
      {:ok, Clients.to_metadata(client, secret), Errors.no_store(ctx)}
    end
    |> to_error()
  end

  @doc "GET /oauth2/public-client"
  def public(%Context{params: params} = ctx) do
    case public_details(ctx, params.client_id) do
      nil -> {:error, not_found()}
      details -> {:ok, details, ctx}
    end
  end

  @doc "What a consent page shows about a client. Nothing secret."
  def public_details(ctx, client_id) do
    case Clients.fetch(ctx, client_id) do
      nil ->
        nil

      client ->
        %{
          client_id: client.client_id,
          client_name: client.name,
          client_uri: client.uri,
          logo_uri: client.icon,
          tos_uri: client.tos_uri,
          policy_uri: client.policy_uri,
          contacts: Clients.list(client.contacts)
        }
    end
  end

  @doc """
  POST /oauth2/register. Signed-in users register clients of their own;
  without a session (when allowed) only public clients, which have no
  secret to keep. Any origin may call it, but the session only counts from
  trusted ones: another site can't register clients in a user's name.
  """
  def register(%Context{raw_params: params} = ctx) do
    user = if Origin.trusted_request?(ctx), do: ctx.user
    opts = Config.opts(ctx)
    metadata = metadata(params)

    cond do
      is_nil(user) and not opts[:allow_unauthenticated_client_registration] ->
        ctx = Context.put_resp_header(ctx, "www-authenticate", ~s(Bearer realm="oauth"))
        {:json, 401, %{error: "invalid_token", error_description: "Sign in to register"}, ctx}

      is_nil(user) and metadata["token_endpoint_auth_method"] not in [nil, "none"] ->
        Errors.json(ctx, "invalid_client_metadata", "Without signing in, only public clients")

      is_nil(user) ->
        register_client(ctx, Map.put(metadata, "token_endpoint_auth_method", "none"), %{})

      true ->
        register_client(ctx, metadata, %{user_id: user.id})
    end
  end

  defp register_client(ctx, metadata, owner) do
    case Clients.create(ctx, metadata, owner) do
      {:ok, client, secret} ->
        {:json, 201, Clients.to_metadata(client, secret), Errors.no_store(ctx)}

      {:error, code, description} ->
        Errors.json(ctx, code, description)

      {:error, %Error{}} ->
        Errors.json(ctx, "invalid_client_metadata")
    end
  end

  # Clients choose their metadata; who owns them and whether they skip
  # consent is the server's call.
  defp metadata(params) when is_map(params),
    do: Map.drop(params, ~w(client_id client_secret user_id reference_id skip_consent disabled))

  defp metadata(_params), do: %{}

  # The user's own clients, and their reference's (an organization's).
  defp owned(%Context{user: user} = ctx, client_id, action) do
    reference = reference(ctx)

    with :ok <- allowed(ctx, action) do
      case Store.get_by(ctx, :oauth_client, client_id: client_id) do
        %{user_id: owner} = client when owner == user.id -> {:ok, client}
        %{reference_id: ^reference} = client when not is_nil(reference) -> {:ok, client}
        _missing_or_others -> {:error, not_found()}
      end
    end
  end

  defp reference(ctx) do
    case Config.opts(ctx)[:client_reference] do
      nil -> nil
      reference -> reference.(ctx)
    end
  end

  defp allowed(ctx, action) do
    opts = Config.opts(ctx)

    case opts[:client_privileges] do
      nil ->
        :ok

      allowed? ->
        if allowed?.(action, ctx) == true, do: :ok, else: {:error, Error.new(:forbidden)}
    end
  end

  defp to_error({:error, code, description}) when is_binary(code),
    do: {:error, Clients.error(code, description)}

  defp to_error(result), do: result

  defp not_found, do: Error.custom(:client_not_found, 404, "No such client")
end
