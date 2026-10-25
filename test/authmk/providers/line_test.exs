defmodule Authmk.Providers.LineTest do
  use Authmk.Test.ProviderCase, provider: :line

  alias Authmk.Test.{FakeProvider, Repo}

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://access.line.me",
        "aud" => "client-id",
        "sub" => "U1234",
        "name" => "Brown",
        "picture" => "https://profile.line-scdn.net/brown",
        "email" => "brown@example.com",
        "iat" => now,
        "exp" => now + 600,
        "nonce" => "n-1"
      },
      overrides
    )
  end

  # Web login ID tokens are signed with the channel secret.
  # (Without the nonce, which the authorization request picks.)
  defp channel_token(claims, secret \\ "client-secret"),
    do: FakeProvider.id_token(JOSE.JWK.from_oct(secret), Map.delete(claims, "nonce"))

  describe "redirect sign-in" do
    test "reads the profile from the ID token", %{browser: browser} do
      %{url: url, user: user} =
        sign_in(browser, token_auth: :post, id_token: channel_token(claims()))

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert "#{uri.host}#{uri.path}" == "access.line.me/oauth2/v2.1/authorize"
      assert query["scope"] == "openid profile email"
      assert query["code_challenge_method"] == "S256"
      assert query["nonce"]

      # LINE doesn't say whether the email is verified.
      assert user["email"] == "brown@example.com"
      assert user["email_verified"] == false
      assert user["name"] == "Brown"
      assert user["image"] == "https://profile.line-scdn.net/brown"
    end

    test "an ID token signed with another secret fails", %{browser: browser} do
      FakeProvider.stub(browser.auth, id_token: channel_token(claims(), "another-secret"))

      {browser, conn} =
        post(browser, "/sign-in/social", %{provider: "line", callback_url: "/done"})

      {_browser, conn} = get(browser, "/callback/line", FakeProvider.approve(json(conn)["url"]))
      assert redirected_to(conn) =~ "error=invalid_id_token"
      assert Repo.aggregate("users", :count) == 0
    end

    test "without an ID token, reads the userinfo endpoint", %{browser: browser} do
      profile = %{"sub" => "U99", "name" => "Cony", "email" => "cony@example.com"}
      %{user: user} = sign_in(browser, routes: %{"/oauth2/v2.1/userinfo" => profile})

      assert user["email"] == "cony@example.com"
      assert user["name"] == "Cony"
    end
  end

  describe "ID token sign-in" do
    setup %{browser: browser} do
      {jwk, jwks} = FakeProvider.signing_key(:ec)
      FakeProvider.stub(browser.auth, jwks: jwks, jwks_path: "/oauth2/v2.1/certs")
      %{jwk: jwk}
    end

    defp sign_in_with_id_token(browser, token) do
      post(browser, "/sign-in/social", %{
        provider: "line",
        id_token: %{token: token, nonce: "n-1"}
      })
    end

    test "a valid token signs in", %{browser: browser, jwk: jwk} do
      {_browser, conn} = sign_in_with_id_token(browser, FakeProvider.id_token(jwk, claims()))

      assert json(conn)["user"]["email"] == "brown@example.com"
      assert json(conn)["user"]["email_verified"] == false
    end

    test "tokens for another channel or issuer are refused", %{browser: browser, jwk: jwk} do
      for overrides <- [%{"aud" => "other-channel"}, %{"iss" => "https://evil.example"}] do
        token = FakeProvider.id_token(jwk, claims(overrides))
        {_browser, conn} = sign_in_with_id_token(browser, token)
        assert json(conn)["error"]["code"] == "invalid_id_token"
      end

      # Only ES256 from LINE's keys, or HS256 with the channel secret.
      {rsa, _jwks} = FakeProvider.signing_key()
      {_browser, conn} = sign_in_with_id_token(browser, FakeProvider.id_token(rsa, claims()))
      assert json(conn)["error"]["code"] == "invalid_id_token"

      assert Repo.aggregate("users", :count) == 0
    end
  end
end
