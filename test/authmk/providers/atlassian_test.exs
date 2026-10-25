defmodule Authmk.Providers.AtlassianTest do
  use Authmk.Test.ProviderCase, provider: :atlassian, provider_opts: [prompt: "consent"]

  import Ecto.Query, only: [from: 2]

  alias Authmk.Test.{FakeProvider, Repo}

  @auth Authmk.Test.Providers.Atlassian.Auth

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "account_id" => "557058:abc",
        "account_type" => "atlassian",
        "email" => "ada@example.com",
        "name" => "Ada Lovelace",
        "picture" => "https://avatar-management.atlassian.com/ada"
      },
      overrides
    )
  end

  test "signs in with the /me profile", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/me" => profile()})

    assert url =~ "https://auth.atlassian.com/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "read:jira-user offline_access"
    assert query["audience"] == "api.atlassian.com"
    assert query["prompt"] == "consent"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://avatar-management.atlassian.com/ada"

    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["557058:abc"]
  end

  test "an email Atlassian claims is verified still isn't trusted", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: %{"/me" => profile(%{"email_verified" => true})})
    assert user["email_verified"] == false
  end

  test "a profile without an email can't sign in", %{browser: browser} do
    FakeProvider.stub(@auth, routes: %{"/me" => Map.delete(profile(), "email")})
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "atlassian"})

    {_browser, conn} =
      get(browser, "/callback/atlassian", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=email_not_found"
  end
end
