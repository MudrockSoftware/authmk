defmodule Authmk.Providers.SpotifyTest do
  use Authmk.Test.ProviderCase, provider: :spotify

  @profile %{
    "id" => "spotify-user",
    "display_name" => "Ada",
    "email" => "ada@example.com",
    "images" => [
      %{"url" => "https://i.scdn.co/ada-large"},
      %{"url" => "https://i.scdn.co/ada-small"}
    ]
  }

  test "signs in with the Spotify profile, using PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/v1/me" => @profile})

    assert url =~ "https://accounts.spotify.com/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "user-read-email"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada"
    assert user["image"] == "https://i.scdn.co/ada-large"
  end

  test "a profile without images has no image", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: %{"/v1/me" => %{@profile | "images" => []}})

    assert user["image"] == nil
  end
end
