defmodule Authmk.Providers.KickTest do
  use Authmk.Test.ProviderCase, provider: :kick

  alias Authmk.Test.{FakeProvider, Repo}

  @user %{
    "user_id" => 123_456,
    "name" => "ada",
    "email" => "ada@example.com",
    "profile_picture" => "https://files.kick.com/images/user/123456/profile_image.webp"
  }

  test "signs in with PKCE as the token's user", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, routes: %{"/public/v1/users" => %{"data" => [@user]}})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "id.kick.com/oauth/authorize"
    assert query["scope"] == "user:read"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "ada"
    assert user["image"] == "https://files.kick.com/images/user/123456/profile_image.webp"
  end

  test "an empty user list refuses sign-in", %{browser: browser, auth: auth} do
    FakeProvider.stub(auth, routes: %{"/public/v1/users" => %{"data" => []}})
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "kick", callback_url: "/done"})
    url = json(conn)["url"]
    {_browser, conn} = get(browser, "/callback/kick", FakeProvider.approve(url))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
    assert Repo.aggregate("users", :count) == 0
  end
end
