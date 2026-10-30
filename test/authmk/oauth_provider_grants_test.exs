defmodule Authmk.OAuthProviderGrantsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        Authmk.Plugins.DeviceAuthorization,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         pairwise_secret: "a pairwise secret of 32 bytes or more!",
         jwt_bearer_subject: &__MODULE__.subject/3}
      ]

    def subject(email, _client, ctx), do: Authmk.Store.get_by(ctx, :user, email: email)
  end

  @moduletag auth: Auth

  @token_endpoint "http://localhost:4000/auth/oauth2/token"

  defp key do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {jwk, Map.put(public, "kid", "k1")}
  end

  defp assertion(jwk, claims) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => @token_endpoint,
          "exp" => now + 60,
          "jti" => Base.encode16(:crypto.strong_rand_bytes(8))
        },
        claims
      )

    {_alg, token} =
      jwk |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "k1"}, claims) |> JOSE.JWS.compact()

    token
  end

  defp token(params, headers \\ []) do
    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil, headers: headers}, "/oauth2/token", params)

    {conn.status, json(conn)}
  end

  test "private_key_jwt: clients prove themselves with their keys, once per assertion" do
    {jwk, public} = key()

    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{"keys" => [public]},
        "scope" => "openid"
      })

    refute Map.has_key?(client, :client_secret)
    signed = assertion(jwk, %{"iss" => client.client_id, "sub" => client.client_id})

    params = %{
      grant_type: "client_credentials",
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: signed
    }

    assert {200, %{"access_token" => _}} = token(params)

    # The same assertion again is a replay.
    assert {401, %{"error" => "invalid_client"}} = token(params)

    # Signed by another key, for another audience, or long-lived: no.
    {other, _public} = key()

    for bad <- [
          assertion(other, %{"iss" => client.client_id}),
          assertion(jwk, %{"iss" => client.client_id, "aud" => "https://elsewhere.example"}),
          assertion(jwk, %{"iss" => client.client_id, "exp" => System.system_time(:second) + 3600}),
          assertion(jwk, %{"iss" => client.client_id, "exp" => System.system_time(:second) - 120}),
          "not.a.jwt"
        ] do
      assert {401, _} = token(%{params | client_assertion: bad})
    end

    # Registration takes public keys only.
    {_kty, private_map} = JOSE.JWK.to_map(jwk)

    assert {:error, %{code: :invalid_client_metadata}} =
             OAuthProvider.create_client(Auth, %{
               "grant_types" => ["client_credentials"],
               "token_endpoint_auth_method" => "private_key_jwt",
               "jwks" => %{"keys" => [private_map]}
             })
  end

  test "private_key_jwt with keys at the client's jwks_uri" do
    {jwk, public} = key()
    test = self()

    Req.Test.stub(Auth, fn conn ->
      send(test, :jwks_fetched)
      Req.Test.json(conn, %{"keys" => [public]})
    end)

    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks_uri" => "https://client.example/jwks.json"
      })

    params = fn ->
      %{
        grant_type: "client_credentials",
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion: assertion(jwk, %{"iss" => client.client_id})
      }
    end

    assert {200, _tokens} = token(params.())
    assert {200, _tokens} = token(params.())
    # Fetched once, then cached.
    assert_received :jwks_fetched
    refute_received :jwks_fetched

    assert {:error, %{code: :invalid_client_metadata}} =
             OAuthProvider.create_client(Auth, %{
               "grant_types" => ["client_credentials"],
               "token_endpoint_auth_method" => "private_key_jwt"
             })
  end

  test "the JWT bearer grant: a trusted client acts for a user" do
    Authmk.Testing.create_user(Auth, email: "ada@example.com")
    {jwk, public} = key()

    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["urn:ietf:params:oauth:grant-type:jwt-bearer"],
        "jwks" => %{"keys" => [public]},
        "scope" => "openid email"
      })

    basic = [
      {"authorization",
       "Basic " <> Base.encode64(client.client_id <> ":" <> client.client_secret)}
    ]

    grant = "urn:ietf:params:oauth:grant-type:jwt-bearer"

    {200, tokens} =
      token(
        %{
          grant_type: grant,
          scope: "openid email",
          assertion: assertion(jwk, %{"iss" => client.client_id, "sub" => "ada@example.com"})
        },
        basic
      )

    assert {:ok, %{user_id: user_id}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"])

    assert user_id
    refute Map.has_key?(tokens, "refresh_token")

    assert {400, %{"error" => "invalid_grant"}} =
             token(
               %{
                 grant_type: grant,
                 assertion:
                   assertion(jwk, %{"iss" => client.client_id, "sub" => "nobody@example.com"})
               },
               basic
             )

    # Only the client's own keys sign for it.
    {other, _public} = key()

    assert {400, %{"error" => "invalid_grant"}} =
             token(
               %{
                 grant_type: grant,
                 assertion:
                   assertion(other, %{"iss" => client.client_id, "sub" => "ada@example.com"})
               },
               basic
             )
  end

  test "the device code grant, through the token endpoint", %{browser: browser} do
    {:ok, tv} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["urn:ietf:params:oauth:grant-type:device_code"],
        "token_endpoint_auth_method" => "none",
        "scope" => "openid profile"
      })

    {_tv, conn} =
      post(%{browser | origin: nil}, "/device/code", %{
        client_id: tv.client_id,
        scope: "openid profile"
      })

    %{"device_code" => device_code, "user_code" => user_code} = json(conn)

    params = %{
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      device_code: device_code,
      client_id: tv.client_id
    }

    assert {400, %{"error" => "authorization_pending"}} = token(params)

    {browser, _user} = sign_up(browser)
    {_browser, _conn} = post(browser, "/device/approve", %{user_code: user_code})

    # Once the interval has passed since the last poll: tokens, once.
    Repo.update_all("device_codes", set: [last_polled_at: nil])

    assert {200, %{"access_token" => _, "id_token" => _, "scope" => "openid profile"}} =
             token(params)

    assert {400, %{"error" => "invalid_grant"}} = token(params)

    {_browser, conn} = get(Browser.new(Auth), "/.well-known/openid-configuration")
    assert json(conn)["device_authorization_endpoint"] == "http://localhost:4000/auth/device/code"
    assert "urn:ietf:params:oauth:grant-type:device_code" in json(conn)["grant_types_supported"]
  end

  test "device codes are only for registered clients with the grant and the scope",
       %{browser: browser} do
    {:ok, web} =
      OAuthProvider.create_client(Auth, %{"redirect_uris" => ["https://web.example/cb"]})

    {:ok, tv} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["urn:ietf:params:oauth:grant-type:device_code"],
        "token_endpoint_auth_method" => "none",
        "scope" => "openid"
      })

    for {client_id, scope, error} <- [
          {"made-up", nil, "invalid_client"},
          {web.client_id, nil, "unauthorized_client"},
          {tv.client_id, "openid email", "invalid_scope"}
        ] do
      {_tv, conn} =
        post(%{browser | origin: nil}, "/device/code", %{client_id: client_id, scope: scope})

      assert {conn.status, json(conn)["error"]} == {400, error}
    end

    assert Repo.aggregate("device_codes", :count) == 0
  end

  # The client lost a scope after the user approved: the code isn't used up.
  test "the scope is checked before the device code is used up", %{browser: browser} do
    {:ok, tv} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["urn:ietf:params:oauth:grant-type:device_code"],
        "token_endpoint_auth_method" => "none",
        "scope" => "openid profile"
      })

    {_tv, conn} =
      post(%{browser | origin: nil}, "/device/code", %{client_id: tv.client_id, scope: "profile"})

    %{"device_code" => device_code, "user_code" => user_code} = json(conn)
    {browser, _user} = sign_up(browser)
    {_browser, _conn} = post(browser, "/device/approve", %{user_code: user_code})

    params = %{
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      device_code: device_code,
      client_id: tv.client_id
    }

    Repo.update_all("oauth_clients", set: [scopes: "openid"])
    assert {400, %{"error" => "invalid_scope"}} = token(params)
    assert Repo.aggregate("device_codes", :count) == 1

    Repo.update_all("oauth_clients", set: [scopes: "openid profile"])
    assert {200, %{"access_token" => _, "scope" => "profile"}} = token(params)
  end

  test "pairwise clients see their own subject for a user", %{browser: browser} do
    pairwise = fn host ->
      {:ok, client} =
        OAuthProvider.create_client(
          Auth,
          %{
            "redirect_uris" => ["https://#{host}/cb"],
            "subject_type" => "pairwise",
            "scope" => "openid"
          },
          skip_consent: true
        )

      client
    end

    {browser, user} = sign_up(browser)

    subject = fn client, host ->
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

      {_browser, conn} =
        get(browser, "/oauth2/authorize", %{
          response_type: "code",
          client_id: client.client_id,
          redirect_uri: "https://#{host}/cb",
          scope: "openid",
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

      code = URI.decode_query(URI.parse(redirected_to(conn)).query)["code"]

      basic = [
        {"authorization",
         "Basic " <> Base.encode64(client.client_id <> ":" <> client.client_secret)}
      ]

      {200, tokens} =
        token(
          %{
            grant_type: "authorization_code",
            code: code,
            redirect_uri: "https://#{host}/cb",
            code_verifier: verifier
          },
          basic
        )

      sub = JOSE.JWT.peek_payload(tokens["id_token"]).fields["sub"]

      # Introspection tells the client the same subject, not the user's id.
      {_client, conn} =
        post(%{Browser.new(Auth) | origin: nil, headers: basic}, "/oauth2/introspect", %{
          token: tokens["access_token"]
        })

      assert json(conn)["sub"] == sub
      sub
    end

    one = subject.(pairwise.("one.example"), "one.example")
    again = subject.(pairwise.("one.example"), "one.example")
    two = subject.(pairwise.("two.example"), "two.example")

    assert one == again
    refute one == two
    refute one == user["id"]

    assert {:error, %{code: :invalid_client_metadata}} =
             OAuthProvider.create_client(Auth, %{
               "redirect_uris" => ["https://a.example/cb", "https://b.example/cb"],
               "subject_type" => "pairwise"
             })
  end
end

defmodule Authmk.OAuthProviderClientURLsTest do
  # Real sockets: a client's jwks_uri on a private network.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in", consent_page: "/consent", trusted_clients: ["internal-app"]}
      ]
  end

  @moduletag auth: Auth

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  defp authenticate(client_id) do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    now = System.system_time(:second)

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => "http://localhost:4000/auth/oauth2/token",
      "exp" => now + 60,
      "jti" => Base.encode16(:crypto.strong_rand_bytes(8))
    }

    {_alg, signed} =
      jwk |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()

    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil}, "/oauth2/token", %{
        grant_type: "client_credentials",
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion: signed
      })

    conn.status
  end

  defp client(port, opts) do
    {:ok, client} =
      OAuthProvider.create_client(
        Auth,
        %{
          "grant_types" => ["client_credentials"],
          "token_endpoint_auth_method" => "private_key_jwt",
          "jwks_uri" => "https://localhost:#{port}/jwks.json"
        },
        opts
      )

    client.client_id
  end

  test "keys on a private network aren't fetched for clients anyone could register" do
    {listener, port} = listen()

    assert authenticate(client(port, [])) == 401
    assert :gen_tcp.accept(listener, 200) == {:error, :timeout}
  end

  test "your trusted clients may keep their keys on a private network" do
    {listener, port} = listen()

    accepted =
      Task.async(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 5_000), do: :gen_tcp.close(socket)
      end)

    assert authenticate(client(port, client_id: "internal-app")) == 401
    assert Task.await(accepted) == :ok
  end
end
