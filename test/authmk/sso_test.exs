defmodule Authmk.SSOTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.SCIM
  alias Authmk.Plugins.SCIM
  alias Authmk.Test.{Browser, FakeProvider, Repo}

  @issuer "https://idp.acme.example"

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
        Authmk.Plugins.Organization,
        Authmk.Plugins.SCIM,
        {Authmk.Plugins.SSO,
         resolve_host: &__MODULE__.resolve_host/1,
         resolve_txt: &__MODULE__.resolve_txt/1,
         can_manage: &__MODULE__.can_manage?/3,
         default_providers: [
           [
             provider_id: "globex",
             issuer: "https://idp.acme.example",
             client_id: "globex-id",
             client_secret: "client-secret",
             domain: "globex.example"
           ]
         ]}
      ]

    # Stand-ins for DNS: one private host, and TXT records the test publishes.
    def resolve_host("idp.internal"), do: {:ok, [{10, 0, 0, 1}]}
    def resolve_host(_host), do: {:ok, [{93, 184, 216, 34}]}

    def resolve_txt(name),
      do: {:ok, Map.get(:persistent_term.get({__MODULE__, :txt}, %{}), name, [])}

    # Organization admins manage its providers.
    def can_manage?(_action, _organization_id, %{user: user}),
      do: user.email == "admin@acme.example"
  end

  defmodule SharedAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, Authmk.SSOTest.Auth}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.SSO,
         shared_redirect_uri: true,
         resolve_user: &__MODULE__.by_employee_id/3,
         default_providers: [
           [
             provider_id: "globex",
             issuer: "https://idp.acme.example",
             client_id: "globex-id",
             client_secret: "client-secret"
           ]
         ]}
      ]

    # Users are found by the employee id the provider sends, not by email.
    def by_employee_id(%{"employee_id" => "E-7"}, _provider, ctx),
      do: {:ok, Authmk.Store.get_by(ctx, :user, email: "boss@globex.example")}

    def by_employee_id(_profile, _provider, _ctx), do: :default
  end

  @moduletag auth: Auth

  @document %{
    "issuer" => @issuer,
    "authorization_endpoint" => @issuer <> "/authorize",
    "token_endpoint" => @issuer <> "/token",
    "userinfo_endpoint" => @issuer <> "/userinfo",
    "jwks_uri" => @issuer <> "/jwks"
  }

  setup do
    :persistent_term.put({Auth, :txt}, %{})
    %{key: stub_idp(nil, "acme-id")}
  end

  # The identity provider: discovery, keys, and an ID token for `nonce`.
  defp stub_idp(nonce, client_id, claims \\ %{}, key \\ nil) do
    {jwk, jwks} = if key, do: key, else: FakeProvider.signing_key()
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => client_id,
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

    FakeProvider.stub(Auth,
      id_token: FakeProvider.id_token(jwk, claims),
      jwks: jwks,
      jwks_path: "/jwks",
      public_routes: %{"/.well-known/openid-configuration" => @document},
      routes: %{"/userinfo" => %{"sub" => claims["sub"]}}
    )

    {jwk, jwks}
  end

  defp register(browser, params \\ %{}) do
    params =
      Map.merge(
        %{
          provider_id: "acme",
          issuer: @issuer,
          domain: "acme.example",
          oidc_config: %{client_id: "acme-id", client_secret: "client-secret"}
        },
        params
      )

    post(browser, "/sso/register", params)
  end

  # Signs in through the provider; returns the browser and where it ended.
  defp sso(browser, params, key, claims \\ %{}) do
    {browser, conn} = post(browser, "/sign-in/sso", Map.merge(%{callback_url: "/done"}, params))
    url = json(conn)["url"] || flunk(inspect(json(conn)))
    query = URI.decode_query(URI.parse(url).query)
    client_id = query["client_id"]
    stub_idp(query["nonce"], client_id, claims, key)

    {browser, conn} =
      get(
        browser,
        URI.parse(query["redirect_uri"]).path |> String.replace_prefix("/auth", ""),
        FakeProvider.approve(url)
      )

    {browser, redirected_to(conn)}
  end

  defp signed_in_email(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]["email"]
  end

  test "register a provider, verify its domain, sign its users in", %{browser: browser, key: key} do
    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})
    {owner, conn} = register(owner)

    assert %{"provider_id" => "acme", "issuer" => @issuer, "domain_verified" => false} =
             json(conn)

    refute Map.has_key?(json(conn), "client_secret")

    # Stored encrypted.
    [config] = Repo.all(from(p in "sso_providers", select: p.oidc_config))
    refute config =~ "client-secret"

    # Unverified: emails at the domain don't go there yet.
    {_anyone, conn} = post(Browser.new(Auth), "/sign-in/sso", %{email: "ada@acme.example"})
    assert json(conn)["error"]["code"] == "sso_provider_not_found"

    # Named outright, it signs in users it creates. Their emails stay
    # unverified, whatever the provider claims: anyone can add a provider,
    # and other sign-in methods trust verified emails.
    {ada, location} = sso(Browser.new(Auth), %{provider_id: "acme"}, key)
    assert location == "/done"
    assert signed_in_email(ada) == "ada@acme.example"
    assert email_verified?("ada@acme.example") == false

    # The TXT record proves the domain.
    {owner, conn} = post(owner, "/sso/request-domain-verification", %{provider_id: "acme"})
    %{"record" => "_authmk-sso.acme.example", "value" => value} = json(conn)
    {owner, conn} = post(owner, "/sso/verify-domain", %{provider_id: "acme"})
    assert json(conn)["error"]["code"] == "domain_not_verified"

    :persistent_term.put({Auth, :txt}, %{"_authmk-sso.acme.example" => ["other", value]})
    {_owner, conn} = post(owner, "/sso/verify-domain", %{provider_id: "acme"})
    assert json(conn) == %{"domain_verified" => true}

    {ada, location} = sso(Browser.new(Auth), %{email: "ada@acme.example"}, key)
    assert location == "/done"
    assert signed_in_email(ada) == "ada@acme.example"

    # Once the domain is proven, it vouches for the users it creates.
    {_grace, "/done"} =
      sso(Browser.new(Auth), %{email: "grace@acme.example"}, key, %{
        "sub" => "acme-3",
        "email" => "grace@acme.example"
      })

    assert email_verified?("grace@acme.example") == true
  end

  defp email_verified?(email) do
    Repo.one!(from(u in "users", where: u.email == ^email, select: u.email_verified)) in [true, 1]
  end

  test "a provider can't claim existing accounts until it owns their domain", %{
    browser: browser,
    key: key
  } do
    {_bob, _user} = sign_up(Browser.new(Auth), %{email: "bob@acme.example"})
    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})
    {owner, _conn} = register(owner)

    {_bob, location} =
      sso(Browser.new(Auth), %{provider_id: "acme"}, key, %{
        "sub" => "acme-2",
        "email" => "bob@acme.example"
      })

    assert location =~ "error=account_not_linked"

    {owner, conn} = post(owner, "/sso/request-domain-verification", %{provider_id: "acme"})
    :persistent_term.put({Auth, :txt}, %{"_authmk-sso.acme.example" => [json(conn)["value"]]})
    {_owner, _conn} = post(owner, "/sso/verify-domain", %{provider_id: "acme"})

    {bob, location} =
      sso(Browser.new(Auth), %{provider_id: "acme"}, key, %{
        "sub" => "acme-2",
        "email" => "bob@acme.example"
      })

    assert location == "/done"
    assert signed_in_email(bob) == "bob@acme.example"
  end

  test "people a directory provisioned for the provider sign in through it", %{
    browser: browser,
    key: key
  } do
    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})
    {owner, _conn} = register(owner)
    {_owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})

    # The directory, tied to the provider, provisions Bob; his domain isn't verified.
    {:ok, connection} =
      SCIM.create_connection(Auth,
        organization_id: json(conn)["id"],
        provider_id: "acme"
      )

    directory = %{
      Browser.new(Auth)
      | origin: nil,
        headers: [{"authorization", "Bearer " <> connection.token}]
    }

    {_directory, conn} =
      Browser.request(directory, :post, "/scim/v2/Users", %{"userName" => "bob@acme.example"})

    assert conn.status == 201, conn.resp_body

    {bob, location} =
      sso(Browser.new(Auth), %{provider_id: "acme"}, key, %{
        "sub" => "acme-2",
        "email" => "bob@acme.example"
      })

    assert location == "/done"
    assert signed_in_email(bob) == "bob@acme.example"
  end

  test "an organization's provider: its admins manage it, its users join it", %{
    browser: browser,
    key: key
  } do
    {admin, _user} = sign_up(browser, %{email: "admin@acme.example"})
    {admin, conn} = post(admin, "/organization/create", %{name: "Acme", slug: "acme"})
    org_id = json(conn)["id"]

    {admin, conn} = register(admin, %{organization_id: org_id})
    assert json(conn)["organization_id"] == org_id

    {member, _user} = sign_up(Browser.new(Auth), %{email: "eve@other.example"})
    {_member, conn} = register(member, %{provider_id: "acme-2", organization_id: org_id})
    assert conn.status == 403

    {ada, _location} = sso(Browser.new(Auth), %{organization_id: org_id}, key)
    {_ada, conn} = get(ada, "/organization/list")
    assert [%{"id" => ^org_id}] = json(conn)

    {_admin, conn} = get(admin, "/sso/providers", %{organization_id: org_id})
    assert [%{"provider_id" => "acme"}] = json(conn)
  end

  test "providers from config, by their domain", %{key: key} do
    {browser, location} =
      sso(Browser.new(Auth), %{email: "ada@globex.example"}, key, %{
        "email" => "ada@globex.example"
      })

    assert location == "/done"
    assert signed_in_email(browser) == "ada@globex.example"
  end

  # A registered provider chose its own endpoints too: authmk only sends its
  # client secret and codes to public hosts, over HTTPS.
  test "a registered provider's endpoints must be HTTPS", %{browser: browser} do
    test = self()
    document = Map.put(@document, "token_endpoint", "http://idp.acme.example/token")

    Req.Test.stub(Auth, fn conn ->
      send(test, {:requested, conn.request_path})
      Req.Test.json(conn, document)
    end)

    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})
    {_owner, conn} = register(owner)
    assert json(conn)["provider_id"] == "acme"

    {browser, conn} = post(Browser.new(Auth), "/sign-in/sso", %{provider_id: "acme"})
    approved = FakeProvider.approve(json(conn)["url"])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {_browser, conn} = get(browser, "/sso/callback/acme", approved)
        assert redirected_to(conn) =~ "error="
      end)

    assert log =~ "host_not_public"
    refute_received {:requested, "/token"}
  end

  test "bad issuers and forged answers are refused", %{browser: browser, key: key} do
    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})

    for {params, message} <- [
          {%{issuer: "https://idp.internal"}, "isn't public"},
          {%{issuer: "http://idp.acme.example"}, "HTTPS"},
          {%{provider_id: "Not Valid"}, "lowercase"},
          {%{oidc_config: %{client_id: "x"}}, "client_secret"}
        ] do
      {_owner, conn} = register(owner, params)
      assert json(conn)["error"]["message"] =~ message
    end

    {owner, _conn} = register(owner)

    # An ID token with another nonce: replayed from elsewhere.
    {browser, conn} = post(Browser.new(Auth), "/sign-in/sso", %{provider_id: "acme"})
    url = json(conn)["url"]
    stub_idp("other-nonce", "acme-id", %{}, key)
    {_browser, conn} = get(browser, "/sso/callback/acme", FakeProvider.approve(url))
    assert redirected_to(conn) =~ "error=invalid_id_token"

    # A callback for another provider than the one started.
    {browser, conn} = post(Browser.new(Auth), "/sign-in/sso", %{provider_id: "acme"})

    {_browser, conn} =
      get(browser, "/sso/callback/globex", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=state_mismatch"

    {_owner, conn} = post(owner, "/sso/delete-provider", %{provider_id: "acme"})
    assert json(conn) == %{"success" => true}
  end

  @tag auth: SharedAuth
  test "one redirect URI for all providers, and the app picks the user", %{key: key} do
    Authmk.Testing.create_user(SharedAuth, email: "boss@globex.example")

    {browser, conn} =
      post(Browser.new(SharedAuth), "/sign-in/sso", %{
        provider_id: "globex",
        callback_url: "/done"
      })

    url = json(conn)["url"]
    query = URI.decode_query(URI.parse(url).query)
    assert query["redirect_uri"] == "http://localhost:4000/auth/sso/callback"

    # The profile names the employee.
    {_jwk, _jwks} =
      stub_idp(
        query["nonce"],
        "globex-id",
        %{"sub" => "g-1", "email" => "someone@else.example", "employee_id" => "E-7"},
        key
      )

    {browser, conn} = get(browser, "/sso/callback", FakeProvider.approve(url))
    assert redirected_to(conn) == "/done"
    assert signed_in_email(browser) == "boss@globex.example"
  end
end
