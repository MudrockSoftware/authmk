defmodule Authmk.OAuthProviderTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.JWT, algorithm: "RS256"},
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         scopes: ["openid", "profile", "email", "offline_access", "read"],
         claims: &__MODULE__.claims/1}
      ]

    def claims(%{user: user}), do: %{"plan" => "pro", "sub" => "forged", "iss" => user.email}
  end

  @moduletag auth: Auth

  @redirect_uri "https://client.example/callback"

  setup do
    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "client_name" => "Client App",
        "redirect_uris" => [@redirect_uri],
        "grant_types" => ["authorization_code", "refresh_token"],
        "scope" => "openid profile email offline_access"
      })

    %{client: client}
  end

  defp query(url), do: URI.decode_query(URI.parse(url).query || "")

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_params(client, challenge, extra \\ %{}) do
    Map.merge(
      %{
        response_type: "code",
        client_id: client.client_id,
        redirect_uri: @redirect_uri,
        scope: "openid profile email offline_access",
        state: "client-state",
        nonce: "client-nonce",
        code_challenge: challenge,
        code_challenge_method: "S256"
      },
      extra
    )
  end

  # The client's server, calling the token endpoint with its secret.
  defp client_server(client) do
    credentials = Base.encode64(client.client_id <> ":" <> client.client_secret)
    %{Browser.new(Auth) | headers: [{"authorization", "Basic " <> credentials}], origin: nil}
  end

  defp token(client, params) do
    {_server, conn} = post(client_server(client), "/oauth2/token", params)
    conn
  end

  # Signs up, approves the client, and returns the browser and a code.
  defp authorize(browser, client, challenge) do
    {browser, conn} = get(browser, "/oauth2/authorize", authorize_params(client, challenge))
    sign_in_page = redirected_to(conn)
    assert "http://localhost:4000/sign-in?" <> _ = sign_in_page
    assert query(sign_in_page)["client_id"] == client.client_id

    {browser, _user} = sign_up(browser)

    {browser, conn} =
      post(browser, "/oauth2/continue", %{oauth_query: query(sign_in_page)["oauth_query"]})

    consent_page = json(conn)["url"]
    assert "http://localhost:4000/consent?" <> _ = consent_page
    assert query(consent_page)["scope"] == "openid profile email offline_access"

    {browser, conn} =
      post(browser, "/oauth2/consent", %{
        oauth_query: query(consent_page)["oauth_query"],
        accept: true
      })

    back = json(conn)["url"]
    assert "https://client.example/callback?" <> _ = back
    assert query(back)["state"] == "client-state"
    assert query(back)["iss"] == "http://localhost:4000/auth"
    {browser, query(back)["code"]}
  end

  test "sign in, consent, code, tokens, user info", %{browser: browser, client: client} do
    {verifier, challenge} = pkce()
    {browser, code} = authorize(browser, client, challenge)

    conn =
      token(client, %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        code_verifier: verifier
      })

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    tokens = json(conn)
    assert tokens["token_type"] == "Bearer"
    assert tokens["expires_in"] == 3600
    assert tokens["scope"] == "openid profile email offline_access"

    # The ID token, checked like a client would: with the JWKS.
    {_browser, conn} = get(Browser.new(Auth), "/jwks")
    [key] = json(conn)["keys"]

    assert {true, %JOSE.JWT{fields: claims}, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], tokens["id_token"])

    assert claims["iss"] == "http://localhost:4000/auth"
    assert claims["aud"] == client.client_id
    assert claims["nonce"] == "client-nonce"
    assert claims["email"] == "ada@example.com"
    assert is_integer(claims["auth_time"])
    # The app's claims come in, but can't replace the protocol's.
    assert claims["plan"] == "pro"
    refute claims["sub"] == "forged"

    {_api, conn} =
      get(
        %{Browser.new(Auth) | headers: [{"authorization", "Bearer " <> tokens["access_token"]}]},
        "/oauth2/userinfo"
      )

    assert %{"sub" => sub, "email" => "ada@example.com", "name" => "Ada"} = json(conn)
    assert sub == claims["sub"]

    # Next time the user already agreed: straight back to the client.
    {_verifier, challenge} = pkce()
    {_browser, conn} = get(browser, "/oauth2/authorize", authorize_params(client, challenge))
    assert "https://client.example/callback?code=" <> _ = redirected_to(conn)

    # Tokens and secrets are stored hashed.
    [stored] = Repo.all(from(t in "oauth_access_tokens", select: t.token))
    refute stored == tokens["access_token"]
    [secret_hash] = Repo.all(from(c in "oauth_clients", select: c.client_secret))
    refute secret_hash == client.client_secret
  end

  test "codes work once, for their client, redirect URI and verifier", %{
    browser: browser,
    client: client
  } do
    {verifier, challenge} = pkce()
    {_browser, code} = authorize(browser, client, challenge)

    good = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: @redirect_uri,
      code_verifier: verifier
    }

    for bad <- [
          %{good | code_verifier: elem(pkce(), 0)},
          %{good | redirect_uri: "https://client.example/other"},
          Map.delete(good, :code_verifier)
        ] do
      # Every failed try uses the code up too.
      conn = token(client, bad)
      assert json(conn)["error"] == "invalid_grant"
    end

    assert json(token(client, good))["error"] == "invalid_grant"
  end

  test "a wrong secret or another client's code fails", %{browser: browser, client: client} do
    {verifier, challenge} = pkce()
    {_browser, code} = authorize(browser, client, challenge)

    params = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: @redirect_uri,
      code_verifier: verifier
    }

    conn = token(%{client | client_secret: "wrong"}, params)
    assert conn.status == 401
    assert json(conn)["error"] == "invalid_client"
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [~s(Basic realm="oauth")]

    {:ok, other} =
      OAuthProvider.create_client(Auth, %{"redirect_uris" => [@redirect_uri], "scope" => "openid"})

    assert json(token(other, params))["error"] == "invalid_grant"
  end

  test "refresh tokens rotate, tolerate a retry, and end the chain on reuse", %{
    browser: browser,
    client: client
  } do
    {verifier, challenge} = pkce()
    {_browser, code} = authorize(browser, client, challenge)

    first =
      json(
        token(client, %{
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @redirect_uri,
          code_verifier: verifier
        })
      )

    second =
      json(token(client, %{grant_type: "refresh_token", refresh_token: first["refresh_token"]}))

    assert second["refresh_token"] != first["refresh_token"]
    assert second["id_token"]

    # The answer got lost and the client retries: still fine, once.
    retry =
      json(token(client, %{grant_type: "refresh_token", refresh_token: first["refresh_token"]}))

    assert retry["access_token"]

    # Narrower scopes may be asked for; wider ones not.
    narrow =
      json(
        token(client, %{
          grant_type: "refresh_token",
          refresh_token: retry["refresh_token"],
          scope: "openid"
        })
      )

    assert narrow["scope"] == "openid"

    assert json(
             token(client, %{
               grant_type: "refresh_token",
               refresh_token: narrow["refresh_token"],
               scope: "openid read"
             })
           )["error"] ==
             "invalid_scope"

    # Much later, the first token shows up again: a leak. Everything ends.
    Repo.update_all("oauth_refresh_tokens",
      set: [revoked_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    assert json(
             token(client, %{grant_type: "refresh_token", refresh_token: first["refresh_token"]})
           )["error"] ==
             "invalid_grant"

    {_api, conn} =
      get(
        %{Browser.new(Auth) | headers: [{"authorization", "Bearer " <> narrow["access_token"]}]},
        "/oauth2/userinfo"
      )

    assert conn.status == 401
  end

  test "introspection and revocation", %{browser: browser, client: client} do
    {verifier, challenge} = pkce()
    {_browser, code} = authorize(browser, client, challenge)

    tokens =
      json(
        token(client, %{
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @redirect_uri,
          code_verifier: verifier
        })
      )

    {_server, conn} =
      post(client_server(client), "/oauth2/introspect", %{token: tokens["access_token"]})

    assert %{"active" => true, "client_id" => client_id, "scope" => _, "sub" => _} = json(conn)
    assert client_id == client.client_id

    {_server, conn} =
      post(client_server(client), "/oauth2/introspect", %{
        token: tokens["refresh_token"],
        token_type_hint: "refresh_token"
      })

    assert json(conn)["token_type"] == "refresh_token"

    assert {:ok, %{scopes: ["openid" | _]}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"], scopes: ["email"])

    assert {:error, %{code: :insufficient_scope}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"], scopes: ["read"])

    # Revoking the refresh token takes the access token with it.
    {_server, conn} =
      post(client_server(client), "/oauth2/revoke", %{token: tokens["refresh_token"]})

    assert conn.status == 200

    {_server, conn} =
      post(client_server(client), "/oauth2/introspect", %{token: tokens["access_token"]})

    assert json(conn) == %{"active" => false}

    assert {:error, %{code: :invalid_token}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"])

    # Unknown tokens get the same answer; a public client can't introspect.
    {_server, conn} = post(client_server(client), "/oauth2/revoke", %{token: "nope"})
    assert conn.status == 200
  end

  test "bad requests stay on this site until the redirect URI is trusted", %{
    browser: browser,
    client: client
  } do
    {_verifier, challenge} = pkce()

    {_browser, conn} =
      get(browser, "/oauth2/authorize", authorize_params(client, challenge, %{client_id: "nope"}))

    assert redirected_to(conn) =~ "http://localhost:4000/auth/error?error=invalid_client"

    {_browser, conn} =
      get(
        browser,
        "/oauth2/authorize",
        authorize_params(client, challenge, %{redirect_uri: "https://evil.example/cb"})
      )

    assert redirected_to(conn) =~ "http://localhost:4000/auth/error?error=invalid_request"

    # Once it is, errors go to the client.
    for {extra, error} <- [
          {%{code_challenge: nil}, "invalid_request"},
          {%{code_challenge_method: "plain"}, "invalid_request"},
          {%{response_type: "token"}, "unsupported_response_type"},
          {%{scope: "openid admin"}, "invalid_scope"},
          {%{prompt: "none"}, "login_required"},
          {%{max_age: "soon"}, "invalid_request"}
        ] do
      params =
        authorize_params(client, challenge, extra) |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {_browser, conn} = get(browser, "/oauth2/authorize", params)
      location = redirected_to(conn)
      assert "https://client.example/callback?" <> _ = location
      assert query(location)["error"] == error, inspect(extra)
      assert query(location)["state"] == "client-state"
    end
  end

  test "consent can be refused, and the signed request can't be changed", %{
    browser: browser,
    client: client
  } do
    {_verifier, challenge} = pkce()
    {browser, _user} = sign_up(browser)
    {browser, conn} = get(browser, "/oauth2/authorize", authorize_params(client, challenge))
    oauth_query = query(redirected_to(conn))["oauth_query"]

    {browser, conn} =
      post(browser, "/oauth2/consent", %{oauth_query: oauth_query <> "x", accept: true})

    assert json(conn)["error"]["code"] == "invalid_oauth_query"

    {browser, conn} =
      post(browser, "/oauth2/consent", %{
        oauth_query: oauth_query,
        accept: true,
        scope: "openid admin"
      })

    assert json(conn)["error"]["code"] == "invalid_scope"

    {_browser, conn} =
      post(browser, "/oauth2/consent", %{oauth_query: oauth_query, accept: false})

    assert query(json(conn)["url"])["error"] == "access_denied"
  end

  test "prompt=login and max_age need a fresh sign-in", %{browser: browser, client: client} do
    {_verifier, challenge} = pkce()
    {browser, _user} = sign_up(browser)

    # An old sign-in.
    Repo.update_all("sessions", set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600)])

    for extra <- [%{prompt: "login"}, %{max_age: "60"}] do
      {browser, conn} =
        get(browser, "/oauth2/authorize", authorize_params(client, challenge, extra))

      sign_in_page = redirected_to(conn)
      assert "http://localhost:4000/sign-in?" <> _ = sign_in_page

      # Continuing without signing in again just comes back here.
      {_browser, conn} =
        post(browser, "/oauth2/continue", %{oauth_query: query(sign_in_page)["oauth_query"]})

      assert "http://localhost:4000/sign-in?" <> _ = json(conn)["url"]
    end

    # After a new sign-in, it goes on.
    {browser, conn} =
      get(browser, "/oauth2/authorize", authorize_params(client, challenge, %{prompt: "login"}))

    oauth_query = query(redirected_to(conn))["oauth_query"]

    {browser, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {_browser, conn} = post(browser, "/oauth2/continue", %{oauth_query: oauth_query})
    assert "http://localhost:4000/consent?" <> _ = json(conn)["url"]
  end

  test "client credentials, for the client itself" do
    {:ok, service} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "scope" => "read openid"
      })

    tokens = json(token(service, %{grant_type: "client_credentials", scope: "read"}))
    assert tokens["scope"] == "read"
    refute Map.has_key?(tokens, "refresh_token")
    refute Map.has_key?(tokens, "id_token")

    assert {:ok, %{user_id: nil, client_id: client_id}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"])

    assert client_id == service.client_id

    assert json(token(service, %{grant_type: "client_credentials", scope: "openid"}))["error"] ==
             "invalid_scope"

    assert json(token(service, %{grant_type: "authorization_code", code: "x"}))["error"] ==
             "unauthorized_client"

    assert json(token(service, %{grant_type: "password"}))["error"] == "unsupported_grant_type"
  end

  test "public clients send their id instead of a secret", %{browser: browser} do
    {:ok, app} =
      OAuthProvider.create_client(Auth, %{
        "redirect_uris" => ["com.example.app:/callback", "http://127.0.0.1/callback"],
        "token_endpoint_auth_method" => "none",
        "application_type" => "native",
        "scope" => "openid"
      })

    refute Map.has_key?(app, :client_secret)
    {verifier, challenge} = pkce()
    {browser, _user} = sign_up(browser)

    # Loopback redirects work on any port (RFC 8252).
    params =
      authorize_params(app, challenge, %{
        redirect_uri: "http://127.0.0.1:53123/callback",
        scope: "openid"
      })

    {browser, conn} = get(browser, "/oauth2/authorize", params)
    oauth_query = query(redirected_to(conn))["oauth_query"]
    {_browser, conn} = post(browser, "/oauth2/consent", %{oauth_query: oauth_query, accept: true})
    code = query(json(conn)["url"])["code"]

    {_app, conn} =
      post(%{Browser.new(Auth) | origin: nil}, "/oauth2/token", %{
        grant_type: "authorization_code",
        client_id: app.client_id,
        code: code,
        redirect_uri: "http://127.0.0.1:53123/callback",
        code_verifier: verifier
      })

    assert json(conn)["access_token"]
  end

  test "the token endpoint takes form posts" do
    {:ok, service} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "token_endpoint_auth_method" => "client_secret_post",
        "scope" => "read"
      })

    body =
      URI.encode_query(%{
        grant_type: "client_credentials",
        client_id: service.client_id,
        client_secret: service.client_secret
      })

    conn =
      Plug.Test.conn(:post, "/oauth2/token", body)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Auth.call(Auth.init([]))

    assert json(conn)["scope"] == "read"

    # Its registered method only: Basic isn't accepted for it.
    credentials = Base.encode64(service.client_id <> ":" <> service.client_secret)

    conn =
      Plug.Test.conn(
        :post,
        "/oauth2/token",
        URI.encode_query(%{grant_type: "client_credentials"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.put_req_header("authorization", "Basic " <> credentials)
      |> Auth.call(Auth.init([]))

    assert json(conn)["error"] == "invalid_client"
  end

  test "user info needs a valid token with the openid scope" do
    {:ok, service} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "scope" => "read"
      })

    access_token = json(token(service, %{grant_type: "client_credentials"}))["access_token"]

    for headers <- [
          [],
          [{"authorization", "Bearer nope"}],
          [{"authorization", "Bearer " <> access_token}]
        ] do
      {_api, conn} = get(%{Browser.new(Auth) | headers: headers}, "/oauth2/userinfo")
      assert conn.status == 401
      assert ["Bearer realm=\"oauth\"" <> _] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    end

    # In a form body too, but not in both places at once.
    {_api, conn} =
      post(%{Browser.new(Auth) | origin: nil}, "/oauth2/userinfo", %{access_token: "nope"})

    assert conn.status == 401
  end

  test "discovery documents" do
    {_browser, conn} = get(Browser.new(Auth), "/.well-known/openid-configuration")
    doc = json(conn)
    assert doc["issuer"] == "http://localhost:4000/auth"
    assert doc["authorization_endpoint"] == "http://localhost:4000/auth/oauth2/authorize"
    assert doc["jwks_uri"] == "http://localhost:4000/auth/jwks"
    assert doc["id_token_signing_alg_values_supported"] == ["RS256"]
    assert doc["code_challenge_methods_supported"] == ["S256"]
    refute Map.has_key?(doc, "registration_endpoint")

    {_browser, conn} = get(Browser.new(Auth), "/.well-known/oauth-authorization-server")
    refute Map.has_key?(json(conn), "userinfo_endpoint")
  end
end
