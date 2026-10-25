defmodule Authmk.Providers.RedditTest do
  use Authmk.Test.ProviderCase, provider: :reddit, provider_opts: [duration: "permanent"]

  alias Authmk.OAuth.Providers

  @profile %{
    "id" => "abc12",
    "name" => "spez",
    "icon_img" => "https://styles.redditmedia.com/spez.png?width=256&s=sig",
    "has_verified_email" => true,
    "oauth_client_id" => "client-id",
    "verified" => true
  }

  test "signs in with HTTP Basic auth and a placeholder email", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :basic, routes: %{"/api/v1/me" => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "www.reddit.com/api/v1/authorize"
    assert query["scope"] == "identity"
    assert query["duration"] == "permanent"
    refute Map.has_key?(query, "code_challenge")

    # has_verified_email is about the real address, not the placeholder.
    assert user["email"] == "abc12@reddit.placeholder.invalid"
    assert user["email_verified"] == false
    assert user["name"] == "spez"
    assert user["image"] == "https://styles.redditmedia.com/spez.png"
  end

  test "users get distinct placeholders", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{"/api/v1/me" => %{@profile | "id" => "xyz9", "icon_img" => nil}})

    assert user["email"] == "xyz9@reddit.placeholder.invalid"
    assert user["image"] == nil
  end

  test "duration only takes Reddit's values" do
    assert_raise NimbleOptions.ValidationError, fn ->
      Providers.build(reddit: [client_id: "id", client_secret: "secret", duration: "forever"])
    end
  end
end
