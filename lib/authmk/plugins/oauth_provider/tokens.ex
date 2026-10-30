defmodule Authmk.Plugins.OAuthProvider.Tokens do
  @moduledoc false
  # Access, refresh and ID tokens. Access and refresh tokens are random and
  # stored hashed; ID tokens are JWTs signed with the JWT plugin's keys.

  import Ecto.Query

  alias Authmk.Plugins.JWT
  alias Authmk.Plugins.OAuthProvider.{Claims, Clients, Config}
  alias Authmk.{Store, Token}

  @doc """
  Issues tokens for a grant and returns the token response.

  `grant`: `:scopes`, and for users `:user`, `:session_id`, `:nonce`,
  `:auth_time`, and when rotating a refresh token `:family_id` and
  `:refresh_scopes` (what the chain was granted, which a narrower request
  doesn't change).
  """
  def issue(ctx, client, grant, opts) do
    refresh_scopes = grant[:refresh_scopes] || grant.scopes

    refresh? =
      grant[:user] != nil and "offline_access" in refresh_scopes and
        "refresh_token" in Clients.list(client.grant_types)

    with {:ok, refresh_token, refresh} <-
           maybe_refresh(ctx, client, %{grant | scopes: refresh_scopes}, refresh?, opts),
         {:ok, access_token} <- insert_access(ctx, client, grant, refresh, opts),
         {:ok, id_token} <- maybe_id_token(ctx, client, grant, opts) do
      {:ok,
       %{
         access_token: access_token,
         token_type: if(grant[:dpop_jkt], do: "DPoP", else: "Bearer"),
         expires_in: opts[:access_token_expires_in],
         scope: Enum.join(grant.scopes, " "),
         refresh_token: refresh_token,
         id_token: id_token
       }
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  # Tokens for a resource are JWTs it can check alone; the rest are random.
  # Either way the hash is kept, for introspection and revocation.
  defp insert_access(ctx, client, grant, refresh, opts) do
    with {:ok, token} <- access_token_value(ctx, client, grant, opts),
         {:ok, _record} <-
           Store.insert(
             ctx,
             :oauth_access_token,
             access_attrs(token, client, grant, refresh, opts)
           ),
         do: {:ok, token}
  end

  defp access_token_value(ctx, client, grant, opts) do
    case grant[:resource] do
      nil -> {:ok, Token.generate(32)}
      _resource -> jwt_access_token(ctx, client, grant, opts)
    end
  end

  # RFC 9068.
  defp jwt_access_token(ctx, client, grant, opts) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => Config.issuer(ctx),
        "aud" => grant.resource,
        "sub" => if(grant[:user], do: Claims.subject(grant.user), else: client.client_id),
        "client_id" => client.client_id,
        "scope" => Enum.join(grant.scopes, " "),
        "iat" => now,
        "exp" => now + opts[:access_token_expires_in],
        "jti" => Token.generate(16),
        "sid" => grant[:session_id],
        "cnf" => grant[:dpop_jkt] && %{"jkt" => grant.dpop_jkt}
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    JWT.sign_claims(ctx, claims, %{"typ" => "at+jwt"})
  end

  defp access_attrs(token, client, grant, refresh, opts) do
    %{
      token: Token.hash(token),
      oauth_client_id: client.id,
      user_id: grant[:user] && grant.user.id,
      session_id: grant[:session_id],
      refresh_token_id: refresh && to_string(refresh.id),
      scopes: Enum.join(grant.scopes, " "),
      resource: grant[:resource],
      reference_id: client.reference_id,
      dpop_jkt: grant[:dpop_jkt],
      expires_at: in_seconds(opts[:access_token_expires_in])
    }
  end

  defp maybe_refresh(_ctx, _client, _grant, false, _opts), do: {:ok, nil, nil}

  defp maybe_refresh(ctx, client, grant, true, opts) do
    token = Token.generate(32)

    attrs = %{
      token: Token.hash(token),
      oauth_client_id: client.id,
      user_id: grant.user.id,
      session_id: grant[:session_id],
      family_id: grant[:family_id],
      scopes: Enum.join(grant.scopes, " "),
      resource: grant[:resource],
      reference_id: client.reference_id,
      auth_time: grant[:auth_time],
      # RFC 9449 5: public clients' refresh tokens are bound too; others
      # prove themselves when they use one.
      dpop_jkt: if(Clients.confidential?(client), do: nil, else: grant[:dpop_jkt]),
      expires_at: in_seconds(opts[:refresh_token_expires_in])
    }

    with {:ok, refresh} <- Store.insert(ctx, :oauth_refresh_token, attrs),
         {:ok, refresh} <- start_family(ctx, refresh) do
      {:ok, token, refresh}
    end
  end

  # The first token of a chain names the chain.
  defp start_family(ctx, %{family_id: nil} = refresh),
    do: Store.update(ctx, :oauth_refresh_token, refresh, %{family_id: to_string(refresh.id)})

  defp start_family(_ctx, refresh), do: {:ok, refresh}

  defp maybe_id_token(ctx, client, %{user: user, scopes: scopes} = grant, opts)
       when not is_nil(user) do
    if "openid" in scopes do
      now = System.system_time(:second)

      claims =
        user
        |> Claims.user_claims(client, scopes, opts)
        |> Map.merge(%{
          "iss" => Config.issuer(ctx),
          "aud" => client.client_id,
          "azp" => client.client_id,
          "iat" => now,
          "exp" => now + opts[:id_token_expires_in],
          "auth_time" => grant[:auth_time] && DateTime.to_unix(grant.auth_time),
          "nonce" => grant[:nonce],
          "sid" => grant[:session_id]
        })
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      JWT.sign_claims(ctx, claims)
    else
      {:ok, nil}
    end
  end

  defp maybe_id_token(_ctx, _client, _grant, _opts), do: {:ok, nil}

  @doc "A live access token and its client, or `nil`."
  def find_access(ctx, token) when is_binary(token) do
    with %{} = access <- Store.get_by(ctx, :oauth_access_token, token: Token.hash(token)),
         true <- DateTime.after?(access.expires_at, DateTime.utc_now()),
         %{disabled: false} = client <-
           Store.get_by(ctx, :oauth_client, id: access.oauth_client_id) do
      {access, client}
    else
      _invalid -> nil
    end
  end

  def find_access(_ctx, _token), do: nil

  @doc "A refresh token by value, used or not, or `nil`."
  def find_refresh(ctx, token) when is_binary(token),
    do: Store.get_by(ctx, :oauth_refresh_token, token: Token.hash(token))

  def find_refresh(_ctx, _token), do: nil

  @doc "Marks a refresh token used, with its access tokens ended."
  def revoke_refresh(ctx, refresh) do
    revoke_access_for(ctx, [to_string(refresh.id)])

    with {:ok, _refresh} <-
           Store.update(ctx, :oauth_refresh_token, refresh, %{revoked_at: DateTime.utc_now()}),
         do: :ok
  end

  @doc "Ends a whole rotation chain: every refresh token and its access tokens."
  def revoke_family(ctx, family_id) do
    family = from(r in Store.module(ctx, :oauth_refresh_token), where: r.family_id == ^family_id)
    ids = Store.list(ctx, :oauth_refresh_token, select(family, [r], r.id))
    revoke_access_for(ctx, Enum.map(ids, &to_string/1))
    Store.update_all(ctx, :oauth_refresh_token, family, set: [revoked_at: DateTime.utc_now()])
    :ok
  end

  defp revoke_access_for(_ctx, []), do: 0

  defp revoke_access_for(ctx, refresh_ids),
    do:
      Store.delete_all(ctx, :oauth_access_token, dynamic([a], a.refresh_token_id in ^refresh_ids))

  @doc "Deletes an access token."
  def delete_access(ctx, access), do: Store.delete(ctx, :oauth_access_token, access)

  defp in_seconds(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)
end
