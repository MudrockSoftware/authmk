defmodule Authmk.MCPTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, Repo}

  @mcp "http://localhost:4000/mcp"
  @resource_metadata "http://localhost:4000/.well-known/oauth-protected-resource/mcp"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        Authmk.Plugins.DeviceAuthorization,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         resources: ["http://localhost:4000/mcp"],
         allow_dynamic_client_registration: true,
         allow_unauthenticated_client_registration: true}
      ]
  end

  # The app: discovery at its root, an MCP server at /mcp.
  defmodule App do
    use Plug.Builder

    plug Authmk.Plug.WellKnown,
      auth: Authmk.MCPTest.Auth,
      protected_resources: [
        [resource: "http://localhost:4000/mcp", scopes: ["openid"], name: "Tools"]
      ]

    plug :mcp

    alias Authmk.Plug.RequireAccessToken

    def mcp(%Plug.Conn{request_path: "/mcp"} = conn, _opts) do
      opts =
        RequireAccessToken.init(
          auth: Authmk.MCPTest.Auth,
          resource: "http://localhost:4000/mcp",
          resource_metadata: "http://localhost:4000/.well-known/oauth-protected-resource/mcp"
        )

      conn = RequireAccessToken.call(conn, opts)

      if conn.halted,
        do: conn,
        else: send_resp(conn, 200, "tools for " <> conn.assigns.current_user.email)
    end

    def mcp(conn, _opts), do: send_resp(conn, 404, "")
  end

  @moduletag auth: Auth

  defp app(method, path, headers \\ []) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path), fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    App.call(conn, App.init([]))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "an MCP client finds its way from a 401 to a token", %{browser: browser} do
    # 1. No token: the server says where to learn more.
    conn = app(:get, "/mcp")
    assert conn.status == 401
    assert header(conn, "www-authenticate") =~ ~s(resource_metadata="#{@resource_metadata}")

    # 2. The resource names its authorization server.
    resource = JSON.decode!(app(:get, "/.well-known/oauth-protected-resource/mcp").resp_body)
    assert resource["resource"] == @mcp
    assert [issuer] = resource["authorization_servers"]
    assert issuer == "http://localhost:4000/auth"

    # 3. Its metadata, at the root with the issuer's path (RFC 8414).
    conn = app(:get, "/.well-known/oauth-authorization-server/auth")
    assert header(conn, "access-control-allow-origin") == "*"
    server = JSON.decode!(conn.resp_body)
    assert server["registration_endpoint"] == "http://localhost:4000/auth/oauth2/register"

    # 4. The client registers itself, from a browser on another origin.
    {_client, conn} =
      Browser.request(
        %{browser | origin: "http://localhost:6274"},
        :options,
        "/oauth2/register",
        %{}
      )

    assert conn.status == 204
    assert header(conn, "access-control-allow-origin") == "*"

    {_client, conn} =
      post(%{browser | origin: "http://localhost:6274"}, "/oauth2/register", %{
        "client_name" => "MCP Inspector",
        "redirect_uris" => ["http://localhost:6274/oauth/callback"]
      })

    assert conn.status == 201
    assert header(conn, "access-control-allow-origin") == "*"
    client_id = json(conn)["client_id"]

    # 5. The user signs in and approves, with the MCP server as resource.
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {browser, _user} = sign_up(browser)

    {browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: client_id,
        redirect_uri: "http://localhost:6274/oauth/callback",
        scope: "openid",
        resource: @mcp,
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    oauth_query = URI.decode_query(URI.parse(redirected_to(conn)).query)["oauth_query"]
    {_browser, conn} = post(browser, "/oauth2/consent", %{oauth_query: oauth_query, accept: true})
    code = URI.decode_query(URI.parse(json(conn)["url"]).query)["code"]

    {_client, conn} =
      post(%{Browser.new(Auth) | origin: "http://localhost:6274"}, "/oauth2/token", %{
        grant_type: "authorization_code",
        client_id: client_id,
        code: code,
        redirect_uri: "http://localhost:6274/oauth/callback",
        code_verifier: verifier,
        resource: @mcp
      })

    assert header(conn, "access-control-allow-origin") == "*"
    token = json(conn)["access_token"]
    assert JOSE.JWT.peek_payload(token).fields["aud"] == @mcp

    # 6. The MCP server takes it.
    conn = app(:get, "/mcp", [{"authorization", "Bearer " <> token}])
    assert conn.resp_body == "tools for ada@example.com"
  end

  test "another site can't register clients in a signed-in user's name", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    {_browser, conn} =
      post(%{browser | origin: "https://evil.example"}, "/oauth2/register", %{
        "redirect_uris" => ["https://evil.example/cb"],
        "token_endpoint_auth_method" => "client_secret_basic"
      })

    # Treated as anonymous: public clients only.
    assert json(conn)["error"] == "invalid_client_metadata"

    {_browser, conn} =
      post(%{browser | origin: "https://evil.example"}, "/oauth2/register", %{
        "redirect_uris" => ["https://evil.example/cb"]
      })

    assert conn.status == 201
    assert [nil] = Repo.all(from(c in "oauth_clients", select: c.user_id))
  end

  test "CLI tools sign in with a device code for the MCP server", %{browser: browser} do
    {_client, conn} =
      post(%{browser | origin: nil}, "/oauth2/register", %{
        "client_name" => "my-cli",
        "grant_types" => ["urn:ietf:params:oauth:grant-type:device_code"]
      })

    client_id = json(conn)["client_id"]

    {_cli, conn} =
      post(%{browser | origin: nil}, "/device/code", %{client_id: client_id, scope: "openid"})

    %{"device_code" => device_code, "user_code" => user_code} = json(conn)

    {browser, _user} = sign_up(browser)
    {_browser, _conn} = post(browser, "/device/approve", %{user_code: user_code})

    {_cli, conn} =
      post(%{Browser.new(Auth) | origin: nil}, "/oauth2/token", %{
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: client_id,
        device_code: device_code,
        resource: @mcp
      })

    conn = app(:get, "/mcp", [{"authorization", "Bearer " <> json(conn)["access_token"]}])
    assert conn.status == 200
  end

  test "documents for unknown resources pass through" do
    assert app(:get, "/.well-known/oauth-protected-resource/other").status == 404
    assert app(:get, "/.well-known/openid-configuration").status == 200
  end
end
