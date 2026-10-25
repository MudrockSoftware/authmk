defmodule Authmk.Providers.RailwayTest do
  use Authmk.Test.ProviderCase, provider: :railway

  @profile %{
    "sub" => "railway-1",
    "email" => "conductor@example.com",
    "name" => "Conductor",
    "picture" => "https://railway.com/c.png"
  }

  test "signs in with HTTP Basic auth and an unverified email", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :basic, routes: %{"/oauth/me" => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "backboard.railway.com/oauth/auth"
    assert query["scope"] == "openid email profile"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "conductor@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Conductor"
    assert user["image"] == "https://railway.com/c.png"
  end

  test "Railway's email_verified claim isn't trusted", %{browser: browser} do
    profile = Map.put(@profile, "email_verified", true)
    %{user: user} = sign_in(browser, routes: %{"/oauth/me" => profile})

    assert user["email_verified"] == false
  end
end
