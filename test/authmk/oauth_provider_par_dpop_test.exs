defmodule Authmk.OAuthProviderPARDPoPTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Plugins.OAuthProvider.DPoP
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         scopes: ["openid", "offline_access", "read"],
         resources: ["https://api.example.com"]}
      ]
  end

  defmodule StrictAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         require_pushed_authorization_requests: true}
      ]
  end

  defmodule API do
    use Plug.Builder

    plug Authmk.Plug.RequireAccessToken, auth: Authmk.OAuthProviderPARDPoPTest.Auth
    plug :ok

    def ok(conn, _opts), do: send_resp(conn, 200, "ok")
  end

  @moduletag auth: Auth

  @redirect_uri "https://client.example/cb"
  @token_url "http://localhost:4000/auth/oauth2/token"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)}
  end

  defp proof(jwk, method, url, extra \\ %{}) do
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    claims =
      Map.merge(
        %{
          "htm" => method,
          "htu" => url,
          "iat" => System.system_time(:second),
          "jti" => Base.encode16(:crypto.strong_rand_bytes(8))
        },
        extra
      )

    header = %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}
    {_alg, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  defp basic(client),
    do:
      {"authorization",
       "Basic " <> Base.encode64(client.client_id <> ":" <> client.client_secret)}

  defp post_token(params, headers) do
    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil, headers: headers}, "/oauth2/token", params)

    {conn.status, json(conn)}
  end

  defp call_api(headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, "http://api.example.com/things"), fn {k, v},
                                                                                     conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    API.call(conn, API.init([])).status
  end

  test "pushed requests: the browser only carries a reference", %{browser: browser} do
    {:ok, client} =
      OAuthProvider.create_client(
        Auth,
        %{"redirect_uris" => [@redirect_uri], "scope" => "openid"},
        skip_consent: true
      )

    {_verifier, challenge} = pkce()

    request = %{
      response_type: "code",
      redirect_uri: @redirect_uri,
      scope: "openid",
      state: "s",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }

    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil, headers: [basic(client)]}, "/oauth2/par", request)

    assert conn.status == 201

    %{
      "request_uri" => "urn:ietf:params:oauth:request_uri:" <> _ = request_uri,
      "expires_in" => 60
    } = json(conn)

    {browser, _user} = sign_up(browser)

    # Another client can't use it.
    {browser, conn} =
      get(browser, "/oauth2/authorize", %{client_id: "someone-else", request_uri: request_uri})

    assert redirected_to(conn) =~ "/auth/error?error=invalid_request_uri"

    {browser, conn} =
      get(browser, "/oauth2/authorize", %{client_id: client.client_id, request_uri: request_uri})

    assert "https://client.example/cb?code=" <> _ = redirected_to(conn)

    # Used up.
    {_browser, conn} =
      get(browser, "/oauth2/authorize", %{client_id: client.client_id, request_uri: request_uri})

    assert redirected_to(conn) =~ "error=invalid_request_uri"

    # Bad requests are refused when pushed, not later.
    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil, headers: [basic(client)]}, "/oauth2/par", %{
        request
        | scope: "admin"
      })

    assert json(conn)["error"] == "invalid_scope"

    {_client, conn} = post(%{Browser.new(Auth) | origin: nil}, "/oauth2/par", request)
    assert json(conn)["error"] == "invalid_client"
  end

  @tag auth: StrictAuth
  test "a server can require pushed requests", %{browser: browser} do
    {:ok, client} = OAuthProvider.create_client(StrictAuth, %{"redirect_uris" => [@redirect_uri]})
    {_verifier, challenge} = pkce()

    {_browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: client.client_id,
        redirect_uri: @redirect_uri,
        scope: "openid",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    assert redirected_to(conn) =~ "/auth/error?error=invalid_request"
  end

  test "DPoP: tokens bound to the client's key" do
    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "scope" => "read",
        "dpop_bound_access_tokens" => true
      })

    key = JOSE.JWK.generate_key({:ec, "P-256"})

    assert {400, %{"error" => "invalid_dpop_proof"}} =
             post_token(%{grant_type: "client_credentials"}, [basic(client)])

    assert {400, %{"error" => "invalid_dpop_proof"}} =
             post_token(%{grant_type: "client_credentials"}, [
               basic(client),
               {"dpop", proof(key, "POST", "https://elsewhere.example/token")}
             ])

    {200, tokens} =
      post_token(%{grant_type: "client_credentials", resource: "https://api.example.com"}, [
        basic(client),
        {"dpop", proof(key, "POST", @token_url)}
      ])

    assert tokens["token_type"] == "DPoP"
    jkt = JOSE.JWK.thumbprint(key)
    assert JOSE.JWT.peek_payload(tokens["access_token"]).fields["cnf"] == %{"jkt" => jkt}

    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil, headers: [basic(client)]}, "/oauth2/introspect", %{
        token: tokens["access_token"]
      })

    assert %{"token_type" => "DPoP", "cnf" => %{"jkt" => ^jkt}} = json(conn)

    token = tokens["access_token"]

    api_proof = fn extra ->
      proof(
        key,
        "GET",
        "http://api.example.com/things",
        Map.merge(%{"ath" => DPoP.hash(token)}, extra)
      )
    end

    good = api_proof.(%{})
    assert call_api([{"authorization", "DPoP " <> token}, {"dpop", good}]) == 200
    # The same proof again is a replay.
    assert call_api([{"authorization", "DPoP " <> token}, {"dpop", good}]) == 401
    # As a plain bearer token: refused.
    assert call_api([{"authorization", "Bearer " <> token}]) == 401
    # Another key, another URL, or no ath.
    other = JOSE.JWK.generate_key({:ec, "P-256"})

    assert call_api([
             {"authorization", "DPoP " <> token},
             {"dpop",
              proof(other, "GET", "http://api.example.com/things", %{
                "ath" => DPoP.hash(token)
              })}
           ]) == 401

    assert call_api([
             {"authorization", "DPoP " <> token},
             {"dpop", api_proof.(%{"htu" => "http://api.example.com/other"})}
           ]) == 401

    assert call_api([
             {"authorization", "DPoP " <> token},
             {"dpop", proof(key, "GET", "http://api.example.com/things")}
           ]) == 401
  end

  test "DPoP: public clients' refresh tokens need the same key", %{browser: browser} do
    {:ok, app} =
      OAuthProvider.create_client(
        Auth,
        %{
          "redirect_uris" => [@redirect_uri],
          "token_endpoint_auth_method" => "none",
          "grant_types" => ["authorization_code", "refresh_token"],
          "scope" => "openid offline_access"
        },
        skip_consent: true
      )

    {browser, _user} = sign_up(browser)
    {verifier, challenge} = pkce()

    {_browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: app.client_id,
        redirect_uri: @redirect_uri,
        scope: "openid offline_access",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    code = URI.decode_query(URI.parse(redirected_to(conn)).query)["code"]
    key = JOSE.JWK.generate_key({:ec, "P-256"})

    {200, tokens} =
      post_token(
        %{
          grant_type: "authorization_code",
          client_id: app.client_id,
          code: code,
          redirect_uri: @redirect_uri,
          code_verifier: verifier
        },
        [{"dpop", proof(key, "POST", @token_url)}]
      )

    # User info, with the token and a proof.
    {_app, conn} =
      get(
        %{
          Browser.new(Auth)
          | headers: [
              {"authorization", "DPoP " <> tokens["access_token"]},
              {"dpop",
               proof(key, "GET", "http://localhost:4000/auth/oauth2/userinfo", %{
                 "ath" => DPoP.hash(tokens["access_token"])
               })}
            ]
        },
        "/oauth2/userinfo"
      )

    assert json(conn)["sub"]

    refresh = %{
      grant_type: "refresh_token",
      client_id: app.client_id,
      refresh_token: tokens["refresh_token"]
    }

    other = JOSE.JWK.generate_key({:ec, "P-256"})

    assert {400, %{"error" => "invalid_dpop_proof"}} =
             post_token(refresh, [{"dpop", proof(other, "POST", @token_url)}])

    assert {400, %{"error" => "invalid_dpop_proof"}} = post_token(refresh, [])

    assert {200, %{"token_type" => "DPoP"}} =
             post_token(refresh, [{"dpop", proof(key, "POST", @token_url)}])
  end
end
