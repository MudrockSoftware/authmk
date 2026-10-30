defmodule PhoenixAppWeb.OAuthProviderTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Plugins.OAuthProvider

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}
  @redirect_uri "https://other-app.example/callback"

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")
  defp query(url), do: URI.decode_query(URI.parse(url).query)

  test "another app signs its users in with this one", %{conn: conn} do
    {:ok, client} =
      OAuthProvider.create_client(PhoenixApp.Auth, %{
        "client_name" => "Other App",
        "redirect_uris" => [@redirect_uri],
        "scope" => "openid profile"
      })

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)

    conn =
      conn
      |> recycle()
      |> get("/auth/oauth2/authorize", %{
        response_type: "code",
        client_id: client.client_id,
        redirect_uri: @redirect_uri,
        scope: "openid profile",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    # Signed in already: straight to the consent page, which names the app.
    consent_page = redirected_to(conn)
    assert "http://localhost:4000/consent?" <> _ = consent_page
    path = URI.parse(consent_page)
    page = conn |> recycle() |> get(path.path <> "?" <> path.query)
    assert html_response(page, 200) =~ "Other App wants to sign you in"

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/oauth2/consent", %{
        oauth_query: query(consent_page)["oauth_query"],
        accept: true
      })

    code = query(json_response(conn, 200)["url"])["code"]

    tokens =
      build_conn()
      |> put_req_header(
        "authorization",
        "Basic " <> Base.encode64(client.client_id <> ":" <> client.client_secret)
      )
      |> post("/auth/oauth2/token", %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        code_verifier: verifier
      })
      |> json_response(200)

    profile =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> get("/api/profile")

    assert json_response(profile, 200) == %{"name" => "Ada"}
    assert build_conn() |> get("/api/profile") |> response(401)
  end
end
