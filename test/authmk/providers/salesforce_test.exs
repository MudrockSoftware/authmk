defmodule Authmk.Providers.SalesforceTest do
  use Authmk.Test.ProviderCase, provider: :salesforce

  import Ecto.Query, only: [from: 2]

  alias Authmk.Test.{FakeProvider, Repo}

  @auth Authmk.Test.Providers.Salesforce.Auth

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "https://login.salesforce.com/id/00Dxx/005xx",
        "user_id" => "005xx",
        "organization_id" => "00Dxx",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada Lovelace",
        "photos" => %{"picture" => "https://sf/picture", "thumbnail" => "https://sf/thumb"}
      },
      overrides
    )
  end

  test "signs in with the userinfo profile", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, routes: %{"/services/oauth2/userinfo" => profile()})

    assert url =~ "https://login.salesforce.com/services/oauth2/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "openid email profile"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://sf/picture"

    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["005xx"]
  end

  test "an email without Salesforce's verified flag is unverified; the thumbnail stands in", %{
    browser: browser
  } do
    %{user: user} =
      sign_in(browser,
        routes: %{
          "/services/oauth2/userinfo" =>
            profile(%{"email_verified" => nil, "photos" => %{"thumbnail" => "https://sf/thumb"}})
        }
      )

    assert user["email_verified"] == false
    assert user["image"] == "https://sf/thumb"
  end

  test "a profile without a user id is refused", %{browser: browser} do
    FakeProvider.stub(@auth,
      routes: %{"/services/oauth2/userinfo" => Map.delete(profile(), "user_id")}
    )

    {browser, conn} = post(browser, "/sign-in/social", %{provider: "salesforce"})

    {_browser, conn} =
      get(browser, "/callback/salesforce", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end
end
