defmodule Authmk.Providers.DropboxTest do
  use Authmk.Test.ProviderCase, provider: :dropbox, provider_opts: [access_type: "offline"]

  defp profile(overrides) do
    Map.merge(
      %{
        "account_id" => "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
        "name" => %{
          "given_name" => "Ada",
          "surname" => "Lovelace",
          "display_name" => "Ada Lovelace"
        },
        "email" => "ada@example.com",
        "email_verified" => true,
        "profile_photo_url" => "https://dl-web.dropbox.com/account_photo/get/dbaphid%3AAAH"
      },
      overrides
    )
  end

  # The call takes no arguments: an empty POST.
  defp sign_in_with(browser, profile) do
    get_current_account = fn conn ->
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      [] = Plug.Conn.get_req_header(conn, "content-type")
      profile
    end

    sign_in(browser, post_routes: %{"/2/users/get_current_account" => get_current_account})
  end

  test "signs in with PKCE and Dropbox's verified flag", %{browser: browser} do
    %{url: url, user: user} = sign_in_with(browser, profile(%{}))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "www.dropbox.com/oauth2/authorize"
    assert query["scope"] == "account_info.read"
    assert query["code_challenge_method"] == "S256"
    assert query["token_access_type"] == "offline"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://dl-web.dropbox.com/account_photo/get/dbaphid%3AAAH"
  end

  test "an unverified email stays unverified", %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"email_verified" => false}))
    assert user["email_verified"] == false
  end
end
