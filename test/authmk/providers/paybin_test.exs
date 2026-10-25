defmodule Authmk.Providers.PaybinTest do
  use Authmk.Test.ProviderCase, provider: :paybin

  alias Authmk.OAuth.Providers
  alias Authmk.Test.FakeProvider

  defp id_token(claims, drop \\ []) do
    {jwk, _jwks} = FakeProvider.signing_key()
    now = System.system_time(:second)

    FakeProvider.id_token(
      jwk,
      Map.merge(
        %{
          "iss" => "https://idp.paybin.io",
          "aud" => "client-id",
          "sub" => "pb-1",
          "email" => "payer@example.com",
          "email_verified" => true,
          "name" => "Payer",
          "picture" => "https://idp.paybin.io/payer.png",
          "iat" => now,
          "exp" => now + 600
        },
        claims
      )
      |> Map.drop(drop)
    )
  end

  test "signs in with the ID token's claims", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, token_auth: :post, id_token: id_token(%{}))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "idp.paybin.io/oauth2/authorize"
    assert query["scope"] == "openid email profile"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "payer@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Payer"
    assert user["image"] == "https://idp.paybin.io/payer.png"
  end

  test "an unverified email, and the username as name", %{browser: browser} do
    token = id_token(%{"email_verified" => false, "preferred_username" => "payer1"}, ["name"])
    %{user: user} = sign_in(browser, id_token: token)

    assert user["email_verified"] == false
    assert user["name"] == "payer1"
  end

  test "without an ID token there is no user", %{browser: browser} do
    FakeProvider.stub(browser.auth, [])

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "paybin", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/paybin", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end

  test "the client secret is required" do
    assert_raise NimbleOptions.ValidationError, ~r/client_secret/, fn ->
      Providers.build(paybin: [client_id: "id"])
    end
  end
end
