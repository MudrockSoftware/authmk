defmodule PlugApp.MCPTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}
  @mcp "http://localhost:4001/mcp"
  @redirect_uri "http://localhost:6274/oauth/callback"

  defp query(url), do: URI.decode_query(URI.parse(url).query)

  defp post_form(path, params, headers \\ []) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, conn -> put_req_header(conn, k, v) end))
    |> call()
  end

  test "an MCP client goes from a 401 to the tools" do
    [challenge] = get_resp_header(get_path("/mcp"), "www-authenticate")

    assert challenge =~
             ~s(resource_metadata="http://localhost:4001/.well-known/oauth-protected-resource/mcp")

    resource = json(get_path("/.well-known/oauth-protected-resource/mcp"))
    assert resource["authorization_servers"] == ["http://localhost:4001/auth"]
    server = json(get_path("/.well-known/oauth-authorization-server/auth"))

    # It registers itself, from its own origin.
    conn =
      conn(
        :post,
        "/auth/oauth2/register",
        JSON.encode!(%{client_name: "Inspector", redirect_uris: [@redirect_uri]})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://localhost:6274")
      |> call()

    assert conn.status == 201
    client_id = json(conn)["client_id"]
    assert server["registration_endpoint"] == "http://localhost:4001/auth/oauth2/register"

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    browser = cookies(post_json("/auth/sign-up/email", @user))

    authorize =
      "/auth/oauth2/authorize?" <>
        URI.encode_query(%{
          response_type: "code",
          client_id: client_id,
          redirect_uri: @redirect_uri,
          scope: "openid profile",
          resource: @mcp,
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

    [consent_page] = get_resp_header(get_path(authorize, browser), "location")

    consent =
      post_json(
        "/auth/oauth2/consent",
        %{oauth_query: query(consent_page)["oauth_query"], accept: true},
        browser
      )

    code = query(json(consent)["url"])["code"]

    tokens =
      json(
        post_form("/auth/oauth2/token", %{
          grant_type: "authorization_code",
          client_id: client_id,
          code: code,
          redirect_uri: @redirect_uri,
          code_verifier: verifier,
          resource: @mcp
        })
      )

    conn =
      conn(:get, "/mcp")
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> call()

    assert json(conn) == %{"tools" => [], "user" => "ada@example.com"}
  end

  test "clients may also name themselves by an HTTPS URL" do
    assert json(get_path("/.well-known/oauth-authorization-server/auth"))[
             "client_id_metadata_document_supported"
           ]

    # Only HTTPS URLs on public hosts are fetched; this one isn't even tried.
    [location] =
      get_resp_header(
        get_path("/auth/oauth2/authorize?client_id=http%3A%2F%2Fclient.example%2Fapp.json"),
        "location"
      )

    assert location =~ "error=invalid_client"
  end
end
