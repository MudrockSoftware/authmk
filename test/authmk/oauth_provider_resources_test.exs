defmodule Authmk.OAuthProviderResourcesTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.JWT, algorithm: "ES256"},
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         scopes: ["openid", "read", "write"],
         resources: ["https://api.example.com"]}
      ]
  end

  # An API of the same app, protected by the plug.
  defmodule API do
    use Plug.Builder

    plug Authmk.Plug.RequireAccessToken,
      auth: Authmk.OAuthProviderResourcesTest.Auth,
      scopes: ["read"],
      resource: "https://api.example.com",
      resource_metadata: "https://api.example.com/.well-known/oauth-protected-resource"

    plug :things

    def things(conn, _opts),
      do: send_resp(conn, 200, JSON.encode!(%{client: conn.assigns.access_token.client_id}))
  end

  @moduletag auth: Auth

  defp service(scope) do
    {:ok, client} =
      OAuthProvider.create_client(Auth, %{
        "grant_types" => ["client_credentials"],
        "scope" => scope
      })

    client
  end

  defp token(client, params) do
    credentials = Base.encode64(client.client_id <> ":" <> client.client_secret)

    server = %{
      Browser.new(Auth)
      | headers: [{"authorization", "Basic " <> credentials}],
        origin: nil
    }

    {_server, conn} =
      post(server, "/oauth2/token", Map.put(params, :grant_type, "client_credentials"))

    json(conn)
  end

  defp call_api(token) do
    conn = Plug.Test.conn(:get, "/things")

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    API.call(conn, API.init([]))
  end

  test "tokens for a resource are JWTs it can check alone" do
    client = service("read write")
    tokens = token(client, %{scope: "read", resource: "https://api.example.com"})

    {_browser, conn} = get(Browser.new(Auth), "/jwks")
    [key] = json(conn)["keys"]

    assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: header}} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["ES256"], tokens["access_token"])

    assert header["typ"] == "at+jwt"
    assert claims["aud"] == "https://api.example.com"
    assert claims["client_id"] == client.client_id
    assert claims["scope"] == "read"
    assert claims["iss"] == "http://localhost:4000/auth"

    conn = call_api(tokens["access_token"])
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"client" => client.client_id}

    assert token(client, %{resource: "https://other.example.com"})["error"] == "invalid_target"
  end

  test "the plug says what's wrong" do
    conn = call_api(nil)
    assert conn.status == 401

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer realm="api", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource")
           ]

    conn = call_api("made-up")
    assert conn.status == 401

    assert [~s(Bearer realm="api", error="invalid_token") <> _] =
             Plug.Conn.get_resp_header(conn, "www-authenticate")

    # Right resource, missing scope.
    client = service("write")

    conn =
      call_api(
        token(client, %{scope: "write", resource: "https://api.example.com"})["access_token"]
      )

    assert conn.status == 403

    assert [~s(Bearer realm="api", error="insufficient_scope", scope="read") <> _] =
             Plug.Conn.get_resp_header(conn, "www-authenticate")

    # A token for no resource (or another one) isn't for this API.
    conn = call_api(token(service("read"), %{scope: "read"})["access_token"])
    assert conn.status == 401
  end
end
