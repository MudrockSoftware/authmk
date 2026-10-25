defmodule Authmk.Providers.ZoomTest do
  use Authmk.Test.ProviderCase, provider: :zoom

  @profile %{
    "id" => "zoom-user",
    "display_name" => "Ada Lovelace",
    "email" => "ada@example.com",
    "pic_url" => "https://zoom.us/p/ada",
    "verified" => 1
  }

  test "signs in with the Zoom profile, using PKCE and no default scopes", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/v2/users/me" => @profile})

    assert url =~ "https://zoom.us/oauth/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    refute Map.has_key?(query, "scope")
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://zoom.us/p/ada"
  end

  test "an unverified Zoom user has an unverified email", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: %{"/v2/users/me" => %{@profile | "verified" => 0}})

    assert user["email_verified"] == false
  end
end

defmodule Authmk.Providers.ZoomWithoutPKCETest do
  # A second Zoom provider under its own name, so it gets its own auth module.
  use Authmk.Test.ProviderCase,
    provider: :zoom_without_pkce,
    provider_opts: [
      provider: Authmk.OAuth.Providers.Zoom,
      pkce: false,
      scopes: ["user:read:user"]
    ]

  test "pkce: false sends no challenge or verifier", %{browser: browser} do
    profile = %{"id" => "zoom-user", "email" => "ada@example.com", "verified" => 1}
    %{url: url, user: user} = sign_in(browser, routes: %{"/v2/users/me" => profile})

    query = URI.decode_query(URI.parse(url).query)
    refute Map.has_key?(query, "code_challenge")
    assert query["scope"] == "user:read:user"
    assert user["email"] == "ada@example.com"
  end
end
