defmodule Authmk.Providers.GitHubTest do
  use Authmk.Test.ProviderCase, provider: :github

  test "signs in with the primary email and GitHub's verified flag", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser,
        routes: %{
          "/user" => %{
            "id" => 1,
            "login" => "octo",
            "name" => nil,
            "email" => nil,
            "avatar_url" => "https://a/1"
          },
          "/user/emails" => [
            %{"email" => "other@example.com", "primary" => false, "verified" => true},
            %{"email" => "octo@example.com", "primary" => true, "verified" => true}
          ]
        }
      )

    assert url =~ "https://github.com/login/oauth/authorize?"
    assert user["email"] == "octo@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "octo"
    assert user["image"] == "https://a/1"
  end
end
