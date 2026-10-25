defmodule Authmk.Providers.CognitoTest do
  use Authmk.Test.ProviderCase,
    provider: :cognito,
    provider_opts: [
      domain: "auth.example.amazoncognito.com",
      region: "us-east-1",
      user_pool_id: "us-east-1_pool",
      identity_provider: "Google"
    ]

  alias Authmk.OAuth.Providers
  alias Authmk.Test.FakeProvider

  @auth Authmk.Test.Providers.Cognito.Auth
  @issuer "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_pool"

  defp claims(overrides) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => "client-id",
        "sub" => "c-123",
        "email" => "ada@example.com",
        "email_verified" => true,
        "cognito:username" => "ada",
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  defp userinfo(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "c-123",
        "email" => "ada@example.com",
        "email_verified" => "true",
        "username" => "ada.l"
      },
      overrides
    )
  end

  test "signs in from the userinfo endpoint", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/oauth2/userinfo" => userinfo()})

    assert url =~ "https://auth.example.amazoncognito.com/oauth2/authorize?"
    # Cognito reads only %20 for spaces.
    assert url =~ "scope=openid%20profile%20email"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "openid profile email"
    assert query["code_challenge_method"] == "S256"
    assert query["identity_provider"] == "Google"
    assert query["nonce"]

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "ada.l"
  end

  test "the ID token's claims come first, and the name falls back to given_name", %{
    browser: browser
  } do
    id_token =
      FakeProvider.signed_id_token(
        claims(%{"given_name" => "Ada", "picture" => "https://p/1", "token_use" => "id"}),
        "/us-east-1_pool/.well-known/jwks.json"
      )

    %{user: user} = sign_in(browser, [routes: %{"/oauth2/userinfo" => userinfo()}] ++ id_token)

    assert user["name"] == "Ada"
    assert user["image"] == "https://p/1"
  end

  test "keeps Cognito's unverified flag", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{"/oauth2/userinfo" => userinfo(%{"email_verified" => "false"})})

    assert user["email_verified"] == false
  end

  describe "ID token sign-in" do
    setup do
      {jwk, jwks} = FakeProvider.signing_key()
      FakeProvider.stub(@auth, jwks: jwks, jwks_path: "/us-east-1_pool/.well-known/jwks.json")
      %{jwk: jwk}
    end

    defp sign_in_with_id_token(browser, token) do
      post(browser, "/sign-in/social", %{
        provider: "cognito",
        id_token: %{token: token, nonce: "n-1"}
      })
    end

    test "a valid token signs in", %{browser: browser, jwk: jwk} do
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1"}))
      {_browser, conn} = sign_in_with_id_token(browser, token)

      assert json(conn)["user"]["email"] == "ada@example.com"
      assert json(conn)["user"]["email_verified"] == true
    end

    test "tokens for another app client or pool are refused", %{browser: browser, jwk: jwk} do
      for overrides <- [
            %{"aud" => "other-client"},
            %{"iss" => "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_other"},
            %{"token_use" => "access"}
          ] do
        token = FakeProvider.id_token(jwk, claims(Map.merge(%{"nonce" => "n-1"}, overrides)))
        {_browser, conn} = sign_in_with_id_token(browser, token)
        assert json(conn)["error"]["code"] == "invalid_id_token"
      end
    end
  end

  test "the user pool is required" do
    assert_raise NimbleOptions.ValidationError, ~r/required :domain option/, fn ->
      Providers.build(cognito: [client_id: "client-id"])
    end
  end
end
