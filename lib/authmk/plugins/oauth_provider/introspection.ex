defmodule Authmk.Plugins.OAuthProvider.Introspection do
  @moduledoc false
  # POST /oauth2/introspect (RFC 7662) and POST /oauth2/revoke (RFC 7009).

  alias Authmk.{Context, Store}
  alias Authmk.Plugins.OAuthProvider.{Claims, Clients, Config, Errors, Tokens}

  # Resource servers authenticate as confidential clients to ask.
  def introspect(%Context{raw_params: params} = ctx) do
    with {:ok, client} <- Clients.authenticate(ctx),
         true <- Clients.confidential?(client) do
      {:json, 200, describe(ctx, params["token"], params["token_type_hint"]),
       Errors.no_store(ctx)}
    else
      _unauthenticated -> Errors.invalid_client(ctx)
    end
  end

  defp describe(ctx, token, hint) when is_binary(token) do
    lookups =
      if hint == "refresh_token",
        do: [&refresh_info/2, &access_info/2],
        else: [&access_info/2, &refresh_info/2]

    Enum.find_value(lookups, %{active: false}, & &1.(ctx, token))
  end

  defp describe(_ctx, _token, _hint), do: %{active: false}

  defp access_info(ctx, token) do
    case Tokens.find_access(ctx, token) do
      {access, client} -> info(ctx, access, client, "Bearer")
      nil -> nil
    end
  end

  defp refresh_info(ctx, token) do
    with %{revoked_at: nil} = refresh <- Tokens.find_refresh(ctx, token),
         true <- DateTime.after?(refresh.expires_at, DateTime.utc_now()),
         %{disabled: false} = client <-
           Store.get_by(ctx, :oauth_client, id: refresh.oauth_client_id) do
      info(ctx, refresh, client, "refresh_token")
    else
      _inactive -> nil
    end
  end

  defp info(ctx, record, client, token_type) do
    %{
      active: true,
      token_type: if(token_type == "Bearer" and record.dpop_jkt, do: "DPoP", else: token_type),
      cnf: record.dpop_jkt && %{jkt: record.dpop_jkt},
      scope: record.scopes,
      client_id: client.client_id,
      sub: subject(ctx, record, client),
      iss: Config.issuer(ctx),
      iat: DateTime.to_unix(record.inserted_at),
      exp: DateTime.to_unix(record.expires_at),
      sid: record.session_id
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The subject the token's client knows the user by: pairwise clients
  # never learn the user's id.
  defp subject(_ctx, %{user_id: nil}, client), do: client.client_id

  defp subject(ctx, record, client),
    do: Claims.subject(%{id: record.user_id}, client, Config.opts(ctx))

  # Only the client a token was issued to can revoke it. Unknown tokens are
  # fine: the answer is the same, so it reveals nothing.
  def revoke(%Context{raw_params: params} = ctx) do
    case Clients.authenticate(ctx) do
      {:ok, client} ->
        :ok = revoke_token(ctx, client, params["token"])
        {:json, 200, %{}, Errors.no_store(ctx)}

      :error ->
        Errors.invalid_client(ctx)
    end
  end

  defp revoke_token(ctx, client, token) when is_binary(token) do
    with nil <- revoke_access(ctx, client, token),
         %{} = refresh <- Tokens.find_refresh(ctx, token),
         true <- refresh.oauth_client_id == client.id do
      # The tokens it gave out go with it.
      Tokens.revoke_family(ctx, refresh.family_id)
    else
      _done_or_unknown -> :ok
    end
  end

  defp revoke_token(_ctx, _client, _token), do: :ok

  defp revoke_access(ctx, client, token) do
    case Tokens.find_access(ctx, token) do
      {access, %{id: id}} when id == client.id ->
        {:ok, _access} = Tokens.delete_access(ctx, access)
        :ok

      _not_this_clients ->
        nil
    end
  end
end
