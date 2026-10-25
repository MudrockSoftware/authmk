defmodule Authmk.Providers.VercelTest do
  use Authmk.Test.ProviderCase,
    provider: :vercel,
    provider_opts: [scopes: ["openid", "email", "profile"]]

  @profile %{
    "sub" => "vercel-user",
    "name" => "Ada Lovelace",
    "preferred_username" => "ada",
    "email" => "ada@example.com",
    "email_verified" => true,
    "picture" => "https://vercel.com/api/www/avatar/ada"
  }

  test "signs in with the Vercel profile, using PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/login/oauth/userinfo" => @profile})

    assert url =~ "https://vercel.com/oauth/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "openid email profile"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://vercel.com/api/www/avatar/ada"
  end

  test "falls back to the username, and to an unverified email", %{browser: browser} do
    profile = @profile |> Map.delete("name") |> Map.delete("email_verified")
    %{user: user} = sign_in(browser, routes: %{"/login/oauth/userinfo" => profile})

    assert user["name"] == "ada"
    assert user["email_verified"] == false
  end
end

defmodule Authmk.Providers.VercelDefaultScopesTest do
  # A second Vercel provider under its own name, so it gets its own auth module.
  use Authmk.Test.ProviderCase,
    provider: :vercel_default,
    provider_opts: [provider: Authmk.OAuth.Providers.Vercel]

  test "requests no scopes unless configured", %{browser: browser} do
    profile = %{"sub" => "vercel-user", "email" => "ada@example.com"}
    %{url: url, user: user} = sign_in(browser, routes: %{"/login/oauth/userinfo" => profile})

    refute Map.has_key?(URI.decode_query(URI.parse(url).query), "scope")
    assert user["email"] == "ada@example.com"
  end
end
