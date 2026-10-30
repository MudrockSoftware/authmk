defmodule Authmk.Plugins.OAuthProvider.PushedRequests do
  @moduledoc false
  # Pushed authorization requests (RFC 9126): the client sends the request
  # straight to the server, authenticated, and the browser carries only a
  # `request_uri`. Nothing in the request can be changed or seen on the way.

  alias Authmk.{Context, Verification}
  alias Authmk.Plugins.OAuthProvider.{Clients, Config, Errors, Requests}

  @purpose "oauth-par"
  @prefix "urn:ietf:params:oauth:request_uri:"
  @expires_in 60
  @client_auth ~w(client_secret client_assertion client_assertion_type)

  @doc "POST /oauth2/par"
  def push(%Context{raw_params: params} = ctx) do
    case Clients.authenticate(ctx) do
      {:ok, client} -> store(ctx, client, Map.drop(params, @client_auth))
      :error -> Errors.invalid_client(ctx)
    end
  end

  defp store(ctx, client, params) do
    opts = Config.opts(ctx)

    cond do
      Map.has_key?(params, "request_uri") ->
        Errors.json(ctx, "invalid_request", "A pushed request can't hold a request_uri")

      not Clients.redirect_uri_allowed?(client, params["redirect_uri"], opts) ->
        Errors.json(ctx, "invalid_request", "redirect_uri isn't registered for this client")

      true ->
        case Requests.check(ctx, client, params, opts) do
          {:ok, _scopes} -> save(ctx, Map.put(params, "client_id", client.client_id))
          {:error, code, description} -> Errors.json(ctx, code, description)
        end
    end
  end

  defp save(ctx, params) do
    {:ok, token} = Verification.create(ctx, @purpose, params, @expires_in)
    {:json, 201, %{request_uri: @prefix <> token, expires_in: @expires_in}, Errors.no_store(ctx)}
  end

  @doc """
  The pushed params, once, when `client_id` is the client that pushed them.
  Another client asking doesn't use the request up.
  """
  def take(ctx, @prefix <> token, client_id) when is_binary(client_id) do
    with {:ok, %{"client_id" => ^client_id}} <- Verification.peek(ctx, @purpose, token),
         {:ok, params} <- Verification.consume(ctx, @purpose, token) do
      {:ok, params}
    else
      _invalid -> :error
    end
  end

  def take(_ctx, _request_uri, _client_id), do: :error
end
