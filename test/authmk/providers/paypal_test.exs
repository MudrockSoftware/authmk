defmodule Authmk.Providers.PayPalTest do
  use Authmk.Test.ProviderCase, provider: :paypal

  alias Authmk.OAuth.Providers
  alias Authmk.Test.{FakeProvider, Repo}

  @profile %{
    "user_id" => "https://www.paypal.com/webapps/auth/identity/user/abc",
    "name" => "Pat Payer",
    "email" => "pat@example.com",
    "email_verified" => true,
    "picture" => "https://www.paypalobjects.com/pat.png"
  }

  @userinfo "/v1/identity/oauth2/userinfo"

  defp id_token(subject) do
    {jwk, _jwks} = FakeProvider.signing_key()
    FakeProvider.id_token(jwk, %{"sub" => subject})
  end

  defp callback_error(browser, fake) do
    FakeProvider.stub(browser.auth, fake)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "paypal", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/paypal", FakeProvider.approve(json(conn)["url"]))
    redirected_to(conn)
  end

  test "signs in with HTTP Basic auth and PayPal's verified flag", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :basic, routes: %{@userinfo => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "www.sandbox.paypal.com/signin/authorize"
    assert query["code_challenge_method"] == "S256"
    assert query["scope"] in [nil, ""]

    assert user["email"] == "pat@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Pat Payer"
    assert user["image"] == "https://www.paypalobjects.com/pat.png"
  end

  test "the ID token's subject must match the profile's", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{@userinfo => @profile}, id_token: id_token(@profile["user_id"]))

    assert user["email"] == "pat@example.com"

    profile = Map.put(@profile, "sub", "subject-1")

    %{user: user} =
      sign_in(browser, routes: %{@userinfo => profile}, id_token: id_token("subject-1"))

    assert user["email"] == "pat@example.com"
  end

  test "a different ID token subject fails sign-in", %{browser: browser} do
    for {profile, subject} <- [
          {@profile, "someone-else"},
          # `sub` wins over `user_id` when the profile has both.
          {Map.put(@profile, "sub", "subject-1"), @profile["user_id"]}
        ] do
      location =
        callback_error(browser, routes: %{@userinfo => profile}, id_token: id_token(subject))

      assert location =~ "error=unable_to_get_user_info"
    end

    assert Repo.aggregate("users", :count) == 0
  end

  test "an unverified email isn't verified", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{@userinfo => %{@profile | "email_verified" => false}})

    assert user["email_verified"] == false
  end

  test "the client secret is required" do
    assert_raise NimbleOptions.ValidationError, ~r/client_secret/, fn ->
      Providers.build(paypal: [client_id: "id"])
    end
  end
end
