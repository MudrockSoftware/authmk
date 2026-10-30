defmodule PhoenixAppWeb.MCPTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}
  @mcp "http://localhost:4000/mcp"
  @redirect_uri "http://localhost:6274/oauth/callback"

  defp query(url), do: URI.decode_query(URI.parse(url).query)

  test "an MCP client goes from a 401 to the tools", %{conn: conn} do
    [challenge] = build_conn() |> get("/mcp") |> get_resp_header("www-authenticate")

    assert challenge =~
             ~s(resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource/mcp")

    resource =
      build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

    assert resource["authorization_servers"] == ["http://localhost:4000/auth"]

    client_id =
      build_conn()
      |> put_req_header("origin", "http://localhost:6274")
      |> post("/auth/oauth2/register", %{client_name: "Inspector", redirect_uris: [@redirect_uri]})
      |> json_response(201)
      |> Map.fetch!("client_id")

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-up/email", @user)

    conn =
      conn
      |> recycle()
      |> get("/auth/oauth2/authorize", %{
        response_type: "code",
        client_id: client_id,
        redirect_uri: @redirect_uri,
        scope: "openid profile",
        resource: @mcp,
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    consent_page = redirected_to(conn)

    conn =
      conn
      |> recycle()
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/oauth2/consent", %{
        oauth_query: query(consent_page)["oauth_query"],
        accept: true
      })

    code = query(json_response(conn, 200)["url"])["code"]

    tokens =
      build_conn()
      |> post("/auth/oauth2/token", %{
        grant_type: "authorization_code",
        client_id: client_id,
        code: code,
        redirect_uri: @redirect_uri,
        code_verifier: verifier,
        resource: @mcp
      })
      |> json_response(200)

    tools =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> get("/mcp")
      |> json_response(200)

    assert tools == %{"tools" => [], "user" => "ada@example.com"}
  end

  test "clients may also name themselves by an HTTPS URL" do
    metadata =
      build_conn() |> get("/.well-known/oauth-authorization-server/auth") |> json_response(200)

    assert metadata["client_id_metadata_document_supported"]

    # Only HTTPS URLs on public hosts are fetched; this one isn't even tried.
    conn =
      build_conn()
      |> get("/auth/oauth2/authorize", %{client_id: "http://client.example/app.json"})

    assert redirected_to(conn) =~ "error=invalid_client"
  end
end
