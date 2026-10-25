defmodule Authmk.OAuth.IDToken do
  @moduledoc """
  Verifies OpenID Connect ID tokens.

  The signature must match a key from the provider's JWKS, with an
  asymmetric algorithm (no `none`, no HMAC), or one of the provider's
  `:id_token_algorithms`. Then `iss` must be the provider's issuer, `aud`
  must include the client id (or another configured `audience`), `exp`
  must be in the future, `iat` not in the future (nor older than the
  provider's `:id_token_max_age`), `nonce` must match, and the provider's
  `validate_claims/2` must accept the claims.

  JWKS documents are cached for an hour, and fetched again when a token
  names an unknown key, so key rotation works without restarts. To keep
  tokens with made-up key ids from hammering the provider, that happens at
  most once every 30 seconds per JWKS (the `:jwks_refetch_cooldown`
  application env, in seconds).
  """

  alias Authmk.Context
  alias Authmk.OAuth.HTTP
  alias Authmk.Storage.ETS

  @algorithms [
    "RS256",
    "RS384",
    "RS512",
    "PS256",
    "PS384",
    "PS512",
    "ES256",
    "ES384",
    "ES512",
    "EdDSA"
  ]
  @cache_ttl 3600
  @clock_skew 60

  @doc """
  The verified claims, or an error. `nonce` is the expected nonce, or a
  list of the accepted ones.

  Options:

    * `nonce_required: false` - a token without a `nonce` claim passes (the
      code exchange, where the token comes straight from the provider); one
      with a different nonce still fails.
    * `key:` - a JWK map to verify with, instead of the provider's JWKS.
    * `algorithms:` - the accepted algorithms, instead of the provider's.
  """
  @spec verify(
          Context.t(),
          Authmk.OAuth.Provider.t(),
          String.t(),
          String.t() | [String.t()] | nil,
          keyword()
        ) :: {:ok, map()} | {:error, atom()}
  def verify(ctx, provider, token, nonce \\ nil, opts \\ [])

  def verify(ctx, provider, token, nonce, opts) when is_binary(token) do
    with {:ok, header} <- header(token),
         {:ok, jwk} <- key(ctx, provider, header["kid"], opts[:key]),
         {:ok, claims} <- verify_signature(algorithms(provider, opts), jwk, token),
         :ok <- check_claims(provider, claims, nonce, Keyword.get(opts, :nonce_required, true)),
         :ok <- provider.module.validate_claims(claims, provider) do
      {:ok, claims}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_id_token}
    end
  end

  def verify(_ctx, _provider, _token, _nonce, _opts), do: {:error, :invalid_id_token}

  defp header(token) do
    {:ok, token |> JOSE.JWS.peek_protected() |> JSON.decode!()}
  rescue
    _malformed -> {:error, :invalid_id_token}
  end

  defp key(ctx, provider, kid, nil), do: signing_key(ctx, provider, kid)
  defp key(_ctx, _provider, _kid, key), do: {:ok, key}

  defp algorithms(provider, opts),
    do: opts[:algorithms] || provider.id_token_algorithms || @algorithms

  defp signing_key(_ctx, %{jwks_url: nil}, _kid), do: {:error, :id_token_not_supported}

  # The cached keys first; fetched again when the key isn't there.
  defp signing_key(ctx, provider, kid) do
    with {:ok, keys} <- jwks(ctx, provider.jwks_url, :cached),
         nil <- find_key(keys, kid),
         :ok <- refetch_allowed(ctx, provider.jwks_url),
         {:ok, keys} <- jwks(ctx, provider.jwks_url, :fresh),
         nil <- find_key(keys, kid) do
      {:error, :invalid_id_token}
    else
      %{} = key -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_key(keys, nil), do: List.first(keys)
  defp find_key(keys, kid), do: Enum.find(keys, &(&1["kid"] == kid))

  defp verify_signature(algorithms, key, token) do
    jwk = JOSE.JWK.from_map(key)

    case JOSE.JWT.verify_strict(jwk, algorithms, token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _invalid -> {:error, :invalid_id_token}
    end
  rescue
    _bad_key_or_token -> {:error, :invalid_id_token}
  end

  defp check_claims(provider, claims, nonce, nonce_required) do
    now = System.system_time(:second)

    checks = [
      issuer_ok?(provider, claims["iss"]),
      Enum.any?(provider.audiences, &(&1 in List.wrap(claims["aud"]))),
      is_integer(claims["exp"]) and claims["exp"] > now - @clock_skew,
      issued_ok?(provider, claims["iat"], now),
      nonce_ok?(claims["nonce"], nonce, nonce_required)
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :invalid_id_token}
  end

  defp issuer_ok?(%{issuer: nil}, _issuer), do: true
  defp issuer_ok?(%{issuer: expected}, issuer), do: issuer in List.wrap(expected)

  # Not from the future, and not older than the provider allows.
  defp issued_ok?(provider, iat, now) when is_integer(iat) do
    max_age = provider.id_token_max_age
    iat <= now + @clock_skew and (is_nil(max_age) or iat >= now - max_age - @clock_skew)
  end

  defp issued_ok?(provider, _missing, _now), do: is_nil(provider.id_token_max_age)

  # Only checked when a nonce was sent with the request.
  defp nonce_ok?(_claimed, nil, _required), do: true
  defp nonce_ok?(nil, _expected, false), do: true
  defp nonce_ok?(claimed, expected, _required), do: same?(claimed, expected)

  defp same?(value, expected) when is_binary(value) and is_list(expected),
    do: Enum.any?(expected, &Plug.Crypto.secure_compare(value, &1))

  defp same?(value, expected) when is_binary(value),
    do: Plug.Crypto.secure_compare(value, expected)

  defp same?(_value, _expected), do: false

  defp refetch_allowed(%Context{config: config}, url) do
    table = [table: ETS.table(config.auth)]
    key = "jwks_refetch:" <> url
    cooldown = Application.get_env(:authmk, :jwks_refetch_cooldown, 30)

    if cooldown > 0 and ETS.get(table, key) do
      {:error, :invalid_id_token}
    else
      if cooldown > 0, do: :ok = ETS.put(table, key, "1", cooldown)
      :ok
    end
  end

  defp jwks(%Context{config: config} = ctx, url, freshness) do
    table = [table: ETS.table(config.auth)]
    key = "jwks:" <> url
    cached = if freshness == :cached, do: ETS.get(table, key)

    case cached do
      nil -> fetch_jwks(ctx, table, key, url)
      json -> {:ok, JSON.decode!(json)}
    end
  end

  defp fetch_jwks(ctx, table, key, url) do
    case HTTP.get(ctx, url) do
      {:ok, 200, %{"keys" => keys}} when is_list(keys) ->
        :ok = ETS.put(table, key, JSON.encode!(keys), @cache_ttl)
        {:ok, keys}

      _failed ->
        {:error, :jwks_unavailable}
    end
  end
end
