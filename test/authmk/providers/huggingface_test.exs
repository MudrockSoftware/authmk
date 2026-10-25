defmodule Authmk.Providers.HuggingFaceTest do
  use Authmk.Test.ProviderCase, provider: :huggingface

  defp profile(overrides) do
    Map.merge(
      %{
        "sub" => "62d1b3f0e1a3e2b1c0a9f8e7",
        "name" => "Ada Lovelace",
        "preferred_username" => "ada",
        "picture" => "https://cdn-avatars.huggingface.co/ada.png",
        "email" => "ada@example.com",
        "email_verified" => true
      },
      overrides
    )
  end

  defp sign_in_with(browser, profile),
    do: sign_in(browser, routes: %{"/oauth/userinfo" => profile})

  test "signs in with PKCE and the userinfo profile", %{browser: browser} do
    %{url: url, user: user} = sign_in_with(browser, profile(%{}))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "huggingface.co/oauth/authorize"
    assert query["scope"] == "openid profile email"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://cdn-avatars.huggingface.co/ada.png"
  end

  test "the email is unverified unless Hugging Face says so, and the username stands in for the name",
       %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"name" => nil, "email_verified" => nil}))
    assert user["email_verified"] == false
    assert user["name"] == "ada"
  end
end
