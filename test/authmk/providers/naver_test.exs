defmodule Authmk.Providers.NaverTest do
  use Authmk.Test.ProviderCase, provider: :naver

  alias Authmk.Test.{FakeProvider, Repo}

  defp me(response, resultcode \\ "00") do
    %{
      "/v1/nid/me" => %{
        "resultcode" => resultcode,
        "message" => "success",
        "response" => response
      }
    }
  end

  @profile %{
    "id" => "naver-1",
    "nickname" => "jin",
    "name" => "Jin",
    "email" => "jin@example.com",
    "profile_image" => "https://phinf.pstatic.net/jin.png"
  }

  test "signs in with an unverified email", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, token_auth: :post, routes: me(@profile))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "nid.naver.com/oauth2.0/authorize"
    assert query["scope"] == "profile email"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "jin@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Jin"
    assert user["image"] == "https://phinf.pstatic.net/jin.png"
  end

  test "falls back to the nickname", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: me(Map.delete(@profile, "name")))
    assert user["name"] == "jin"
  end

  test "an error result code fails sign-in", %{browser: browser} do
    FakeProvider.stub(browser.auth, routes: me(@profile, "024"))

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "naver", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/naver", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
    assert Repo.aggregate("users", :count) == 0
  end
end
