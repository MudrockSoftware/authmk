defmodule Authmk.Providers.CloudflareTest do
  use Authmk.Test.ProviderCase, provider: :cloudflare

  import Ecto.Query, only: [from: 2]

  alias Authmk.Test.{FakeProvider, Repo}

  @auth Authmk.Test.Providers.Cloudflare.Auth
  @user "/client/v4/user"

  defp response(user), do: %{"success" => true, "errors" => [], "result" => user}

  defp failed_sign_in(browser, fake) do
    FakeProvider.stub(@auth, fake)
    {browser, conn} = post(browser, "/sign-in/social", %{provider: "cloudflare"})

    {_browser, conn} =
      get(browser, "/callback/cloudflare", FakeProvider.approve(json(conn)["url"]))

    redirected_to(conn)
  end

  test "signs in with the API's user, authenticating with HTTP Basic", %{browser: browser} do
    user = %{
      "id" => "cf-1",
      "email" => "ada@example.com",
      "first_name" => "Ada",
      "last_name" => "Lovelace"
    }

    %{url: url, user: user} = sign_in(browser, routes: %{@user => response(user)})

    assert url =~ "https://dash.cloudflare.com/oauth2/auth?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "user-details.read"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == nil

    assert Repo.all(from(a in "accounts", select: a.account_id)) == ["cf-1"]
  end

  test "without names, the email is the name", %{browser: browser} do
    user = %{"id" => "cf-2", "email" => "nameless@example.com", "first_name" => nil}
    %{user: user} = sign_in(browser, routes: %{@user => response(user)})
    assert user["name"] == "nameless@example.com"
  end

  test "API errors and missing users are refused", %{browser: browser} do
    for body <- [
          %{"success" => false, "errors" => [%{"code" => 1000}], "result" => nil},
          %{"success" => true, "errors" => [], "result" => nil}
        ] do
      assert failed_sign_in(browser, routes: %{@user => body}) =~ "error=unable_to_get_user_info"
    end
  end
end
