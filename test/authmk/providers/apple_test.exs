defmodule Authmk.Providers.AppleTest do
  use Authmk.Test.ProviderCase, provider: :apple

  alias Authmk.Test.FakeProvider

  @auth Authmk.Test.Providers.Apple.Auth

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://appleid.apple.com",
        "aud" => "client-id",
        "sub" => "001234.abcd",
        "email" => "ada@privaterelay.appleid.com",
        "email_verified" => "true",
        "is_private_email" => "true",
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  # A token response with an ID token, and Apple's keys to check it.
  defp id_token(claims), do: FakeProvider.signed_id_token(claims, "/auth/keys")

  test "signs in with the ID token's email", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, id_token(claims()))

    assert url =~ "https://appleid.apple.com/auth/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "email name"
    assert query["response_mode"] == "form_post"
    assert query["code_challenge_method"] == "S256"
    assert query["nonce"]

    assert user["email"] == "ada@privaterelay.appleid.com"
    assert user["email_verified"] == true
    assert user["name"] == "ada"
    assert user["image"] == nil
  end

  test "takes the name from the user param Apple posts on the first sign-in", %{
    browser: browser
  } do
    FakeProvider.stub(@auth, id_token(claims()))

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "apple", callback_url: "/done"})

    user =
      JSON.encode!(%{name: %{firstName: "Ada", lastName: "Lovelace"}, email: "x@evil.example"})

    params = Map.put(FakeProvider.approve(json(conn)["url"]), "user", user)

    # Apple posts cross-site; the POST redirects to a same-site GET.
    {browser, conn} = post(browser, "/callback/apple", params)
    "http://localhost:4000/auth" <> path = redirected_to(conn)
    {browser, conn} = get(browser, path)
    assert redirected_to(conn) == "/done"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["name"] == "Ada Lovelace"
    assert json(conn)["user"]["email"] == "ada@privaterelay.appleid.com"
  end

  test "keeps Apple's unverified flag", %{browser: browser} do
    %{user: user} = sign_in(browser, id_token(claims(%{"email_verified" => false})))
    assert user["email_verified"] == false
  end

  test "fails with an ID token Apple didn't sign", %{browser: browser} do
    {other_key, _jwks} = FakeProvider.signing_key()
    {_jwk, jwks} = FakeProvider.signing_key()
    token = FakeProvider.id_token(other_key, claims())
    FakeProvider.stub(@auth, id_token: token, jwks: jwks, jwks_path: "/auth/keys")

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "apple", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/apple", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=invalid_id_token"
  end

  test "fails without an ID token", %{browser: browser} do
    FakeProvider.stub(@auth, [])

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "apple", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/apple", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end

  describe "ID token sign-in" do
    setup do
      {jwk, jwks} = FakeProvider.signing_key()
      FakeProvider.stub(@auth, jwks: jwks, jwks_path: "/auth/keys")
      %{jwk: jwk}
    end

    defp sign_in_with_id_token(browser, token) do
      post(browser, "/sign-in/social", %{
        provider: "apple",
        id_token: %{token: token, nonce: "n-1"}
      })
    end

    test "a valid token signs in", %{browser: browser, jwk: jwk} do
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => "n-1"}))
      {_browser, conn} = sign_in_with_id_token(browser, token)

      assert json(conn)["user"]["email"] == "ada@privaterelay.appleid.com"
      assert json(conn)["user"]["email_verified"] == true
    end

    test "native apps' hashed nonce is accepted", %{browser: browser, jwk: jwk} do
      hashed = :sha256 |> :crypto.hash("n-1") |> Base.encode16(case: :lower)
      token = FakeProvider.id_token(jwk, claims(%{"nonce" => hashed}))
      {_browser, conn} = sign_in_with_id_token(browser, token)

      assert json(conn)["user"]["email"] == "ada@privaterelay.appleid.com"
    end

    test "tokens for another audience or issuer are refused", %{browser: browser, jwk: jwk} do
      hour_ago = System.system_time(:second) - 3700

      for overrides <- [
            %{"aud" => "com.someone.else"},
            %{"iss" => "https://evil.example"},
            %{"nonce" => "other"},
            %{"iat" => hour_ago}
          ] do
        token = FakeProvider.id_token(jwk, claims(Map.merge(%{"nonce" => "n-1"}, overrides)))
        {_browser, conn} = sign_in_with_id_token(browser, token)
        assert json(conn)["error"]["code"] == "invalid_id_token"
      end
    end
  end
end
