defmodule Authmk.Providers.LinkedInTest do
  use Authmk.Test.ProviderCase, provider: :linkedin

  alias Authmk.Test.FakeProvider

  @auth Authmk.Test.Providers.Linkedin.Auth

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "li-123",
        "name" => "Ada Lovelace",
        "given_name" => "Ada",
        "family_name" => "Lovelace",
        "picture" => "https://media.licdn.com/ada",
        "email" => "ada@example.com",
        "email_verified" => true
      },
      overrides
    )
  end

  test "signs in with the userinfo profile, without PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/v2/userinfo" => profile()})

    assert url =~ "https://www.linkedin.com/oauth/v2/authorization?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "profile email openid"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://media.licdn.com/ada"
  end

  test "an email without LinkedIn's verified flag is unverified", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{"/v2/userinfo" => Map.delete(profile(), "email_verified")})

    assert user["email_verified"] == false
  end

  test "a profile without an email can't sign in", %{browser: browser} do
    FakeProvider.stub(@auth, routes: %{"/v2/userinfo" => Map.delete(profile(), "email")})
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "linkedin"})
    {_browser, conn} = get(browser, "/callback/linkedin", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=email_not_found"
  end
end
