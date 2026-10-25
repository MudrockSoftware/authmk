defmodule Authmk.Providers.FigmaTest do
  use Authmk.Test.ProviderCase, provider: :figma

  alias Authmk.OAuth.Providers

  @profile %{
    "id" => "1234",
    "email" => "ada@example.com",
    "handle" => "Ada",
    "img_url" => "https://s3-alpha.figma.com/profile/1234"
  }

  test "signs in with PKCE and HTTP Basic client auth", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :basic, routes: %{"/v1/me" => @profile})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "www.figma.com/oauth"
    assert query["scope"] == "current_user:read"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada"
    assert user["image"] == "https://s3-alpha.figma.com/profile/1234"
  end

  test "the client secret is required" do
    assert_raise NimbleOptions.ValidationError, ~r/client_secret/, fn ->
      Providers.build(figma: [client_id: "client-id"])
    end
  end
end
