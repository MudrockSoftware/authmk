defmodule Authmk.Providers.RobloxTest do
  use Authmk.Test.ProviderCase, provider: :roblox

  alias Authmk.Test.FakeProvider

  @profile %{
    "sub" => "1234",
    "preferred_username" => "builderman",
    "nickname" => "Builder",
    "name" => "Builder",
    "picture" => "https://tr.rbxcdn.com/1234.png"
  }

  test "signs in with a placeholder email", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :post, routes: %{"/oauth/v1/userinfo" => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "apis.roblox.com/oauth/v1/authorize"
    assert query["scope"] == "openid profile"
    assert query["prompt"] == "select_account consent"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "1234@roblox.placeholder.invalid"
    assert user["email_verified"] == false
    assert user["name"] == "Builder"
    assert user["image"] == "https://tr.rbxcdn.com/1234.png"
  end

  test "falls back to the username", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{"/oauth/v1/userinfo" => Map.delete(@profile, "nickname")})

    assert user["name"] == "builderman"
  end

  test "a subject that can't make an email fails sign-in", %{browser: browser} do
    profile = Map.put(@profile, "sub", "a@b")
    FakeProvider.stub(browser.auth, routes: %{"/oauth/v1/userinfo" => profile})

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "roblox", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/roblox", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end
end

defmodule Authmk.Providers.RobloxPromptTest do
  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      social_providers: [
        roblox: [client_id: "client-id", client_secret: "client-secret", prompt: "login"]
      ]
  end

  use Authmk.EmulationCase, async: true

  @moduletag auth: Auth

  test "the prompt option replaces the default", %{browser: browser} do
    {_browser, conn} = post(browser, "/sign-in/social", %{provider: "roblox"})
    url = json(conn)["url"]

    assert URI.decode_query(URI.parse(url).query)["prompt"] == "login"
    assert length(String.split(url, "prompt=")) == 2
  end
end
