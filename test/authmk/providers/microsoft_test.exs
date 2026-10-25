defmodule Authmk.Providers.MicrosoftTest do
  use Authmk.Test.ProviderCase, provider: :microsoft

  import Ecto.Query, only: [from: 2]

  alias Authmk.Test.{FakeProvider, Repo}

  @auth Authmk.Test.Providers.Microsoft.Auth
  @tenant "11111111-2222-3333-4444-555555555555"
  @photo_path "/v1.0/me/photos/48x48/$value"

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://login.microsoftonline.com/#{@tenant}/v2.0",
        "aud" => "client-id",
        "tid" => @tenant,
        "sub" => "pairwise-sub",
        "oid" => "stable-oid",
        "email" => "ada@contoso.example",
        "name" => "Ada Lovelace",
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  # A token response with an ID token, and Microsoft's keys to check it.
  defp id_token(claims), do: FakeProvider.signed_id_token(claims, "/common/discovery/v2.0/keys")

  defp failed_sign_in(browser, fake) do
    FakeProvider.stub(@auth, fake)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "microsoft", callback_url: "/done"})

    {_browser, conn} =
      get(browser, "/callback/microsoft", FakeProvider.approve(json(conn)["url"]))

    redirected_to(conn)
  end

  test "signs in with the ID token and the Graph photo", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(
        browser,
        [routes: %{@photo_path => {:raw, "image/jpeg", <<255, 216, 255>>}}] ++
          id_token(claims(%{"email_verified" => true}))
      )

    assert url =~ "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "openid profile email User.Read offline_access"
    assert query["code_challenge_method"] == "S256"
    assert query["nonce"]

    assert user["email"] == "ada@contoso.example"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "data:image/jpeg;base64,/9j/"

    # Accounts are keyed by the stable oid, not the pairwise sub.
    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["stable-oid"]
  end

  test "without the email_verified claim, the verified email lists decide", %{browser: browser} do
    %{user: user} =
      sign_in(browser, id_token(claims(%{"verified_primary_email" => ["ada@contoso.example"]})))

    assert user["email_verified"] == true
    assert user["image"] == nil
  end

  test "an email Microsoft doesn't vouch for is unverified", %{browser: browser} do
    %{user: user} = sign_in(browser, id_token(claims()))
    assert user["email_verified"] == false
  end

  test "refuses tokens without an oid", %{browser: browser} do
    for bad <- [Map.delete(claims(), "oid"), claims(%{"oid" => 123})] do
      assert failed_sign_in(browser, id_token(bad)) =~ "error=unable_to_get_user_info"
    end
  end

  test "refuses tokens whose issuer isn't their own tenant's", %{browser: browser} do
    for bad <- [
          claims(%{"iss" => "https://login.microsoftonline.com/other-tenant/v2.0"}),
          claims(%{"iss" => "https://evil.example/#{@tenant}/v2.0"}),
          Map.delete(claims(), "tid")
        ] do
      assert failed_sign_in(browser, id_token(bad)) =~ "error=invalid_id_token"
    end

    assert Repo.aggregate("users", :count) == 0
  end

  describe "ID token sign-in" do
    setup do
      {jwk, jwks} = FakeProvider.signing_key()
      FakeProvider.stub(@auth, jwks: jwks, jwks_path: "/common/discovery/v2.0/keys")
      %{jwk: jwk}
    end

    defp sign_in_with_id_token(browser, token) do
      post(browser, "/sign-in/social", %{
        provider: "microsoft",
        id_token: %{token: token, nonce: "n-1"}
      })
    end

    test "a valid token from any tenant signs in", %{browser: browser, jwk: jwk} do
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1"}))
      {_browser, conn} = sign_in_with_id_token(browser, token)
      assert json(conn)["user"]["email"] == "ada@contoso.example"
    end

    test "a token for another app is refused", %{browser: browser, jwk: jwk} do
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1", "aud" => "other-app"}))
      {_browser, conn} = sign_in_with_id_token(browser, token)
      assert json(conn)["error"]["code"] == "invalid_id_token"
    end

    test "a token whose issuer doesn't name its tenant is refused", %{browser: browser, jwk: jwk} do
      issuer = "https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0"
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1", "iss" => issuer}))
      {_browser, conn} = sign_in_with_id_token(browser, token)
      assert json(conn)["error"]["code"] == "invalid_id_token"
    end

    test "a token older than an hour is refused", %{browser: browser, jwk: jwk} do
      iat = System.system_time(:second) - 3700
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1", "iat" => iat}))
      {_browser, conn} = sign_in_with_id_token(browser, token)
      assert json(conn)["error"]["code"] == "invalid_id_token"
    end
  end
end

defmodule Authmk.Providers.MicrosoftTenantTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.FakeProvider

  @tenant "11111111-2222-3333-4444-555555555555"
  @consumers "9188040d-6c67-4c5b-b112-36a304b66dad"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers:
        for(
          {id, tenant} <- [
            organizations: "organizations",
            consumers: "consumers",
            single: "11111111-2222-3333-4444-555555555555"
          ],
          do:
            {id,
             [
               provider: Authmk.OAuth.Providers.Microsoft,
               client_id: "client-id",
               client_secret: "client-secret",
               tenant_id: tenant,
               authority: "https://login.example.us"
             ]}
        ),
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  # Signs in to `provider` with an ID token from `tid`; returns the error code.
  defp sign_in(browser, provider, tid) do
    {jwk, jwks} = FakeProvider.signing_key()
    tenant = %{organizations: "organizations", consumers: "consumers", single: @tenant}[provider]
    FakeProvider.stub(Auth, jwks: jwks, jwks_path: "/#{tenant}/discovery/v2.0/keys")
    now = System.system_time(:second)

    token =
      FakeProvider.id_token(jwk, %{
        "iss" => "https://login.example.us/#{tid}/v2.0",
        "aud" => "client-id",
        "tid" => tid,
        "oid" => "oid-#{tid}",
        "email" => "ada@#{tid}.example",
        "iat" => now,
        "exp" => now + 600
      })

    {_browser, conn} =
      post(browser, "/sign-in/social", %{provider: provider, id_token: %{token: token}})

    json(conn)["error"]["code"]
  end

  test "organizations allows work accounts, not personal ones", %{browser: browser} do
    assert sign_in(browser, :organizations, @tenant) == nil
    assert sign_in(browser, :organizations, @consumers) == "invalid_id_token"
  end

  test "consumers allows personal accounts only", %{browser: browser} do
    assert sign_in(browser, :consumers, @consumers) == nil
    assert sign_in(browser, :consumers, @tenant) == "invalid_id_token"
  end

  test "a tenant id allows that tenant only", %{browser: browser} do
    assert sign_in(browser, :single, @tenant) == nil
    assert sign_in(browser, :single, @consumers) == "invalid_id_token"
  end

  test "the authorization URL uses the authority and tenant", %{browser: browser} do
    {_browser, conn} = post(browser, "/sign-in/social", %{provider: "single"})
    assert json(conn)["url"] =~ "https://login.example.us/#{@tenant}/oauth2/v2.0/authorize?"
  end
end

defmodule Authmk.Providers.MicrosoftOptionsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{FakeProvider, ProviderCase}

  @tenant "11111111-2222-3333-4444-555555555555"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        microsoft: [
          client_id: "client-id",
          client_secret: "client-secret",
          profile_photo_size: 96,
          authorize_url: "https://login.microsoftonline.com/contoso/oauth2/v2.0/authorize"
        ],
        microsoft_no_photo: [
          provider: Authmk.OAuth.Providers.Microsoft,
          client_id: "client-id",
          client_secret: "client-secret",
          disable_profile_photo: true
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  defp id_token do
    now = System.system_time(:second)

    FakeProvider.signed_id_token(
      %{
        "iss" => "https://login.microsoftonline.com/#{@tenant}/v2.0",
        "aud" => "client-id",
        "tid" => @tenant,
        "oid" => "oid-1",
        "email" => "ada@contoso.example",
        "iat" => now,
        "exp" => now + 600
      },
      "/common/discovery/v2.0/keys"
    )
  end

  test "uses the configured tenant URL and photo size", %{browser: browser} do
    %{url: url, user: user} =
      ProviderCase.sign_in_through(
        browser,
        Auth,
        :microsoft,
        [routes: %{"/v1.0/me/photos/96x96/$value" => {:raw, "image/jpeg", "img"}}] ++ id_token()
      )

    assert url =~ "https://login.microsoftonline.com/contoso/oauth2/v2.0/authorize?"
    assert user["image"] == "data:image/jpeg;base64,aW1n"
  end

  test "disable_profile_photo skips the photo", %{browser: browser} do
    %{user: user} =
      ProviderCase.sign_in_through(
        browser,
        Auth,
        :microsoft_no_photo,
        [routes: %{"/v1.0/me/photos/48x48/$value" => {:raw, "image/jpeg", "img"}}] ++ id_token()
      )

    assert user["image"] == nil
  end
end
