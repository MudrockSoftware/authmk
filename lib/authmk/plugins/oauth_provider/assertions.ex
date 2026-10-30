defmodule Authmk.Plugins.OAuthProvider.Assertions do
  @moduledoc false
  # JWTs a client signs with its own keys: for `private_key_jwt` client
  # authentication and the JWT bearer grant (RFC 7523). Keys come from the
  # client's `jwks`, or its `jwks_uri` (cached for 5 minutes, never through
  # redirects). Each assertion works once.

  import Ecto.Query

  alias Authmk.{Context, Store, Token}
  alias Authmk.OAuth.HTTP
  alias Authmk.Storage.ETS

  @algorithms ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)
  @max_lifetime 300
  @clock_skew 30
  @jwks_cache_ttl 300

  def algorithms, do: @algorithms

  @doc "The `iss` of an assertion, unverified: only to find which client to check it with."
  def issuer(assertion) when is_binary(assertion) do
    case assertion |> JOSE.JWT.peek_payload() |> Map.get(:fields) do
      %{"iss" => iss} when is_binary(iss) -> {:ok, iss}
      _none -> :error
    end
  rescue
    _malformed -> :error
  end

  def issuer(_assertion), do: :error

  @doc """
  Checks an assertion from `client`: signed by one of its keys, issued by
  it, for one of `audiences`, short-lived, and never seen before. Returns
  the claims.
  """
  def verify(ctx, client, assertion, audiences) do
    with {:ok, claims} <- signed_claims(ctx, client, assertion),
         :ok <- check_claims(claims, client, audiences),
         :ok <- use_once(ctx, client, claims) do
      {:ok, claims}
    else
      _invalid -> :error
    end
  end

  defp signed_claims(ctx, client, assertion) do
    with {:ok, %{"alg" => alg} = header} <- protected_header(assertion),
         true <- alg in @algorithms,
         [_ | _] = keys <- keys(ctx, client) do
      keys
      |> Enum.filter(&(header["kid"] in [nil, &1["kid"]]))
      |> Enum.find_value(:error, &verified_with(&1, alg, assertion))
    else
      _invalid -> :error
    end
  rescue
    _malformed -> :error
  end

  defp verified_with(key, alg, assertion) do
    case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), [alg], assertion) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _no -> nil
    end
  end

  defp protected_header(assertion) do
    case assertion |> JOSE.JWS.peek_protected() |> JSON.decode() do
      {:ok, %{} = header} -> {:ok, header}
      _invalid -> :error
    end
  end

  defp check_claims(claims, client, audiences) do
    now = System.system_time(:second)
    exp = claims["exp"]

    cond do
      claims["iss"] != client.client_id -> :error
      not is_binary(claims["jti"]) -> :error
      not is_integer(exp) or exp < now - @clock_skew -> :error
      exp > now + @max_lifetime + @clock_skew -> :error
      not Enum.any?(List.wrap(claims["aud"]), &(&1 in audiences)) -> :error
      true -> :ok
    end
  end

  # The unique key turns a replay into a failed insert.
  defp use_once(ctx, client, claims) do
    expires_at = DateTime.from_unix!(claims["exp"] + @clock_skew)
    key = Token.hash(client.client_id <> ":" <> claims["jti"])
    _count = forget_expired(ctx)

    case Store.insert(ctx, :oauth_assertion, %{key: key, expires_at: expires_at}) do
      {:ok, _assertion} -> :ok
      {:error, _taken} -> :error
    end
  end

  defp forget_expired(ctx) do
    now = DateTime.utc_now()
    Store.delete_all(ctx, :oauth_assertion, dynamic([a], a.expires_at < ^now))
  end

  @doc "The client's public keys (JWKS entries), or `[]`."
  def keys(ctx, client) do
    cond do
      is_binary(client.jwks) -> jwks_keys(JSON.decode(client.jwks))
      is_binary(client.jwks_uri) -> remote_keys(ctx, client.jwks_uri)
      true -> []
    end
  end

  defp jwks_keys({:ok, %{"keys" => keys}}) when is_list(keys), do: Enum.filter(keys, &is_map/1)
  defp jwks_keys(_invalid), do: []

  defp remote_keys(%Context{config: config} = ctx, uri) do
    table = [table: ETS.table(config.auth)]
    cache_key = "oauth-client-jwks:" <> uri

    case ETS.get(table, cache_key) do
      nil ->
        case HTTP.get(ctx, uri) do
          {:ok, 200, %{"keys" => keys}} when is_list(keys) ->
            :ok = ETS.put(table, cache_key, JSON.encode!(keys), @jwks_cache_ttl)
            Enum.filter(keys, &is_map/1)

          _failed ->
            []
        end

      json ->
        JSON.decode!(json)
    end
  end
end
