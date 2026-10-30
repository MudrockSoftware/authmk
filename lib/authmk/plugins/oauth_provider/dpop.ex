defmodule Authmk.Plugins.OAuthProvider.DPoP do
  @moduledoc false
  # DPoP (RFC 9449): tokens bound to a key the client holds. Each request
  # carries a proof, a JWT signed with that key for this method and URL,
  # used once. A stolen token is useless without the key.

  alias Authmk.Plugins.OAuthProvider.Assertions
  alias Authmk.{Store, Token}

  @max_age 60
  @clock_skew 30

  @doc """
  Checks the `DPoP` proof of a request: returns the key's thumbprint
  (`jkt`), `:none` when there's no proof, or `:error`.

  `access_token`: when calling an API, the proof must name the token
  (`ath`).
  """
  def verify(ctx, conn, method, url, access_token \\ nil) do
    case Plug.Conn.get_req_header(conn, "dpop") do
      [] -> :none
      [proof] -> check(ctx, proof, method, url, access_token)
      _several -> :error
    end
  end

  defp check(ctx, proof, method, url, access_token) do
    with {:ok, header, jwk} <- header_key(proof),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(jwk, [header["alg"]], proof),
         :ok <- check_claims(claims, method, url, access_token),
         jkt = JOSE.JWK.thumbprint(jwk),
         :ok <- use_once(ctx, jkt, claims) do
      {:ok, jkt}
    else
      _invalid -> :error
    end
  rescue
    _malformed -> :error
  end

  # The public key rides in the header; private parts mean a broken client.
  defp header_key(proof) do
    with {:ok, %{"typ" => "dpop+jwt", "alg" => alg, "jwk" => %{} = key} = header} <-
           proof |> JOSE.JWS.peek_protected() |> JSON.decode(),
         true <- alg in Assertions.algorithms(),
         false <- Map.has_key?(key, "d") do
      {:ok, header, JOSE.JWK.from_map(key)}
    else
      _invalid -> :error
    end
  end

  defp check_claims(claims, method, url, access_token) do
    now = System.system_time(:second)
    iat = claims["iat"]

    cond do
      claims["htm"] != method -> :error
      not same_url?(claims["htu"], url) -> :error
      not is_binary(claims["jti"]) -> :error
      not is_integer(iat) or abs(now - iat) > @max_age -> :error
      access_token && claims["ath"] != hash(access_token) -> :error
      true -> :ok
    end
  end

  # RFC 9449 4.3: without query and fragment.
  defp same_url?(htu, url) when is_binary(htu) do
    strip = fn value -> URI.to_string(%{URI.parse(value) | query: nil, fragment: nil}) end
    strip.(htu) == strip.(url)
  end

  defp same_url?(_htu, _url), do: false

  defp use_once(ctx, jkt, claims) do
    key = Token.hash("dpop:" <> jkt <> ":" <> claims["jti"])
    expires_at = DateTime.from_unix!(claims["iat"] + @max_age + @clock_skew)

    case Store.insert(ctx, :oauth_assertion, %{key: key, expires_at: expires_at}) do
      {:ok, _seen} -> :ok
      {:error, _replay} -> :error
    end
  end

  @doc "`ath`: the access token's hash, as proofs name it."
  def hash(access_token),
    do: :sha256 |> :crypto.hash(access_token) |> Base.url_encode64(padding: false)
end
