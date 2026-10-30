defmodule PhoenixApp.IdentityProvider do
  @moduledoc false
  # Plays acme's OpenID Connect provider in tests: discovery, keys, and
  # tokens for the nonce of the sign-in under way.

  @issuer "https://idp.acme.example"

  def stub(nonce, claims \\ %{}) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => "acme-id",
          "sub" => "acme-1",
          "email" => "ada@acme.example",
          "email_verified" => true,
          "name" => "Ada",
          "iat" => now,
          "exp" => now + 600,
          "nonce" => nonce
        },
        claims
      )

    {_alg, id_token} =
      jwk |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "acme"}, claims) |> JOSE.JWS.compact()

    Req.Test.stub(PhoenixApp.Providers, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "authorization_endpoint" => @issuer <> "/authorize",
            "token_endpoint" => @issuer <> "/token",
            "userinfo_endpoint" => @issuer <> "/userinfo",
            "jwks_uri" => @issuer <> "/jwks"
          })

        "/jwks" ->
          Req.Test.json(conn, %{"keys" => [Map.put(public, "kid", "acme")]})

        "/token" ->
          Req.Test.json(conn, %{
            "access_token" => "at",
            "token_type" => "Bearer",
            "id_token" => id_token
          })

        "/userinfo" ->
          Req.Test.json(conn, %{"sub" => claims["sub"]})
      end
    end)
  end
end
