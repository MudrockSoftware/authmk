defmodule Authmk.Providers.PolarTest do
  use Authmk.Test.ProviderCase, provider: :polar

  @profile %{
    "id" => "polar-1",
    "email" => "maker@example.com",
    "username" => "maker",
    "public_name" => "Maker",
    "avatar_url" => "https://polar.sh/maker.png",
    "email_verified" => true
  }

  test "signs in with Polar's verified flag", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :post, routes: %{"/v1/oauth2/userinfo" => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "polar.sh/oauth2/authorize"
    assert query["scope"] == "openid profile email"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "maker@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Maker"
    assert user["image"] == "https://polar.sh/maker.png"
  end

  test "without the claim, the email isn't verified", %{browser: browser} do
    profile = Map.drop(@profile, ["email_verified", "public_name"])
    %{user: user} = sign_in(browser, routes: %{"/v1/oauth2/userinfo" => profile})

    assert user["email_verified"] == false
    assert user["name"] == "maker"
  end
end
