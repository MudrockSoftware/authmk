defmodule Authmk.GenericOAuthTest do
  # Providers configured by discovery or by hand, sign-in started by the
  # provider, and logout passed on to it.
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{FakeProvider, Repo}

  @issuer "https://idp.example.com"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        acme: [
          provider: :generic,
          name: "Acme",
          issuer: "https://idp.example.com",
          client_id: "acme-id",
          client_secret: "client-secret",
          id_token_sign_in: true,
          idp_initiated_login: true
        ],
        legacy: [
          provider: :generic,
          authorize_url: "https://legacy.example/oauth/authorize",
          token_url: "https://legacy.example/oauth/token",
          userinfo_url: "https://legacy.example/api/me",
          client_id: "legacy-id",
          client_secret: "client-secret",
          disable_default_scopes: true,
          scopes: ["profile"],
          profile_map: [id: "uid", email: "mail", email_verified: "confirmed", image: nil]
        ],
        # Its document names another issuer than its URL.
        impostor: [
          provider: :generic,
          discovery_url: "https://idp.example.com/other/.well-known/openid-configuration",
          client_id: "acme-id",
          client_secret: "client-secret"
        ],
        keycloak: [
          issuer: "https://idp.example.com",
          client_id: "acme-id",
          client_secret: "client-secret"
        ],
        okta: [
          issuer: "https://idp.example.com",
          client_id: "acme-id",
          client_secret: "client-secret"
        ],
        auth0: [domain: "idp.example.com", client_id: "acme-id", client_secret: "client-secret"]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  @document %{
    "issuer" => @issuer,
    "authorization_endpoint" => @issuer <> "/authorize",
    "token_endpoint" => @issuer <> "/token",
    "userinfo_endpoint" => @issuer <> "/userinfo",
    "jwks_uri" => @issuer <> "/jwks",
    "end_session_endpoint" => @issuer <> "/logout",
    "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
  }

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => "acme-id",
        "sub" => "u-1",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada",
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  # The identity provider: discovery, keys, and Basic auth only.
  defp stub_idp(fake \\ []) do
    {jwk, jwks} = FakeProvider.signing_key()

    FakeProvider.stub(
      Auth,
      [
        token_auth: :basic,
        id_token: FakeProvider.id_token(jwk, claims()),
        jwks: jwks,
        jwks_path: "/jwks",
        public_routes: %{
          "/.well-known/openid-configuration" => @document,
          "/other/.well-known/openid-configuration" => @document
        },
        routes: %{
          "/userinfo" => %{"sub" => "u-1", "picture" => "https://idp.example.com/ada.png"}
        }
      ] ++ fake
    )

    jwk
  end

  defp sign_in(browser, provider \\ "acme") do
    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: provider, callback_url: "/done"})

    url = json(conn)["url"]
    {browser, conn} = get(browser, "/callback/#{provider}", FakeProvider.approve(url))
    {browser, conn, url}
  end

  describe "by discovery" do
    test "the issuer's document gives the endpoints, keys and client auth", %{browser: browser} do
      stub_idp()
      {browser, conn, url} = sign_in(browser)

      assert url =~ "https://idp.example.com/authorize?"
      assert redirected_to(conn) == "/done"

      {_browser, conn} = get(browser, "/get-session")
      user = json(conn)["user"]
      assert user["email"] == "ada@example.com"
      assert user["email_verified"] == true
      # The userinfo endpoint adds to the ID token's claims.
      assert user["image"] == "https://idp.example.com/ada.png"
    end

    test "presets discover from their issuer too", %{browser: browser} do
      stub_idp()

      for provider <- ["keycloak", "okta", "auth0"] do
        {_browser, conn, url} = sign_in(browser, provider)

        assert url =~ "https://idp.example.com/authorize?"
        assert redirected_to(conn) == "/done"
      end
    end

    test "a document for another issuer is refused", %{browser: browser} do
      stub_idp()

      {_browser, conn} =
        post(browser, "/sign-in/social", %{provider: "impostor", callback_url: "/done"})

      assert json(conn)["error"]["code"] == "discovery_failed"
    end

    test "clients may sign in with the provider's ID token", %{browser: browser} do
      jwk = stub_idp()
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1"}))

      {_browser, conn} =
        post(browser, "/sign-in/social", %{
          provider: "acme",
          id_token: %{token: token, nonce: "n-1"}
        })

      assert json(conn)["user"]["email"] == "ada@example.com"
    end
  end

  test "by hand, with the profile's own field names", %{browser: browser} do
    profile = %{"uid" => 7, "mail" => "grace@example.com", "confirmed" => true, "name" => "Grace"}
    FakeProvider.stub(Auth, routes: %{"/api/me" => profile})

    {browser, conn, url} = sign_in(browser, "legacy")
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "profile"
    assert redirected_to(conn) == "/done"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "grace@example.com"
    assert json(conn)["user"]["email_verified"] == true
    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["7"]
  end

  test "a callback can't finish another provider's flow", %{browser: browser} do
    stub_idp()
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "acme"})
    params = FakeProvider.approve(json(conn)["url"])

    {_browser, conn} = get(browser, "/callback/legacy", params)
    assert redirected_to(conn) =~ "error=state_mismatch"
  end

  describe "sign-in started by the provider" do
    test "starts a flow that ends at the target", %{browser: browser} do
      stub_idp()

      {browser, conn} =
        get(browser, "/sign-in/initiate/acme", %{
          iss: @issuer,
          login_hint: "ada@example.com",
          target_link_uri: "/welcome"
        })

      url = redirected_to(conn)
      assert url =~ "https://idp.example.com/authorize?"
      assert URI.decode_query(URI.parse(url).query)["login_hint"] == "ada@example.com"

      {_browser, conn} = get(browser, "/callback/acme", FakeProvider.approve(url))
      assert redirected_to(conn) == "/welcome"
    end

    test "needs the provider's issuer, a trusted target, and the provider's opt-in", %{
      browser: browser
    } do
      stub_idp()

      for {provider, params} <- [
            {"acme", %{iss: "https://evil.example"}},
            {"acme", %{}},
            {"acme", %{iss: @issuer, target_link_uri: "https://evil.example/"}},
            {"keycloak", %{iss: @issuer}}
          ] do
        {_browser, conn} = get(browser, "/sign-in/initiate/#{provider}", params)
        assert redirected_to(conn) =~ ~r/error=(forbidden|invalid_callback_url)/
      end
    end
  end

  test "signing out at the provider too", %{browser: browser} do
    stub_idp()
    {browser, _conn, _url} = sign_in(browser)
    [id_token] = Repo.all(from(a in "accounts", select: a.id_token))

    {browser, conn} = post(browser, "/sign-out/social", %{provider: "acme", callback_url: "/bye"})
    %{"url" => url, "redirect" => true} = json(conn)

    assert url =~ "https://idp.example.com/logout?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["id_token_hint"] == id_token
    assert query["client_id"] == "acme-id"
    assert query["post_logout_redirect_uri"] == "http://localhost:4000/bye"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil
  end
end
