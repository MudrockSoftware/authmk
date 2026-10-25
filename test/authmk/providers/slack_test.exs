defmodule Authmk.Providers.SlackTest do
  use Authmk.Test.ProviderCase, provider: :slack

  import Ecto.Query, only: [from: 2]

  alias Authmk.Test.{FakeProvider, Repo}

  @auth Authmk.Test.Providers.Slack.Auth
  @userinfo "/api/openid.connect.userInfo"

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "ok" => true,
        "sub" => "U123",
        "https://slack.com/user_id" => "U123",
        "https://slack.com/team_id" => "T123",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada Lovelace",
        "picture" => "https://avatars.slack-edge.com/ada.png",
        "https://slack.com/user_image_512" => "https://avatars.slack-edge.com/ada_512.png"
      },
      overrides
    )
  end

  test "signs in with the userinfo profile, without PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{@userinfo => profile()})

    assert url =~ "https://slack.com/openid/connect/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "openid profile email"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://avatars.slack-edge.com/ada.png"

    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["U123"]
  end

  test "the 512px image stands in for a missing picture; unverified stays unverified", %{
    browser: browser
  } do
    %{user: user} =
      sign_in(browser,
        routes: %{@userinfo => profile(%{"picture" => nil, "email_verified" => false})}
      )

    assert user["image"] == "https://avatars.slack-edge.com/ada_512.png"
    assert user["email_verified"] == false
  end

  test "a Slack error answer is refused", %{browser: browser} do
    FakeProvider.stub(@auth, routes: %{@userinfo => %{"ok" => false, "error" => "invalid_auth"}})
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "slack"})
    {_browser, conn} = get(browser, "/callback/slack", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end
end
