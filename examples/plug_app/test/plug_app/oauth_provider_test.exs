defmodule PlugApp.OAuthProviderTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Plugins.OAuthProvider

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}
  @redirect_uri "https://other-app.example/callback"

  defp query(url), do: URI.decode_query(URI.parse(url).query)

  test "another app signs its users in with this one" do
    # The other app, registered once (in a seed script, or by a user).
    {:ok, client} =
      OAuthProvider.create_client(PlugApp.Auth, %{
        "client_name" => "Other App",
        "redirect_uris" => [@redirect_uri],
        "scope" => "openid profile email"
      })

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    authorize =
      "/auth/oauth2/authorize?" <>
        URI.encode_query(%{
          response_type: "code",
          client_id: client.client_id,
          redirect_uri: @redirect_uri,
          scope: "openid profile",
          state: "xyz",
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

    # Not signed in: to the sign-in page, which then continues the request.
    [sign_in_page] = get_resp_header(get_path(authorize), "location")
    assert "http://localhost:4001/sign-in?" <> _ = sign_in_page

    browser = cookies(post_json("/auth/sign-up/email", @user))

    continue =
      post_json(
        "/auth/oauth2/continue",
        %{oauth_query: query(sign_in_page)["oauth_query"]},
        browser
      )

    consent_page = json(continue)["url"]
    assert "http://localhost:4001/consent?" <> _ = consent_page

    # The consent page shows the app, and the user allows it.
    details = json(get_path("/auth/oauth2/public-client?client_id=" <> client.client_id))
    assert details["client_name"] == "Other App"

    consent =
      post_json(
        "/auth/oauth2/consent",
        %{oauth_query: query(consent_page)["oauth_query"], accept: true},
        browser
      )

    back = json(consent)["url"]
    assert query(back)["state"] == "xyz"

    # The other app's server trades the code for tokens, and calls the API.
    conn =
      conn(
        :post,
        "/auth/oauth2/token",
        URI.encode_query(%{
          grant_type: "authorization_code",
          code: query(back)["code"],
          redirect_uri: @redirect_uri,
          code_verifier: verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header(
        "authorization",
        "Basic " <> Base.encode64(client.client_id <> ":" <> client.client_secret)
      )
      |> call()

    %{"access_token" => access_token, "id_token" => _} = json(conn)

    conn =
      conn(:get, "/api/profile")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> call()

    assert json(conn) == %{"name" => "Ada"}

    assert get_path("/api/profile").status == 401
  end

  test "the discovery document" do
    doc = json(get_path("/auth/.well-known/openid-configuration"))
    assert doc["issuer"] == "http://localhost:4001/auth"
    assert doc["token_endpoint"] == "http://localhost:4001/auth/oauth2/token"
  end
end
