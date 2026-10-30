defmodule Authmk.OAuthProviderClientsTest do
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
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         allow_dynamic_client_registration: true,
         allow_unauthenticated_client_registration: true}
      ]
  end

  defmodule SignedInOnlyAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         allow_dynamic_client_registration: true,
         client_privileges: &__MODULE__.privileges/2}
      ]

    # Only admins manage clients here.
    def privileges(_action, %{user: user}), do: user.email == "admin@example.com"
  end

  @moduletag auth: Auth

  @app %{
    "client_name" => "My App",
    "redirect_uris" => ["https://app.example/callback"],
    "scope" => "openid email"
  }

  test "users manage their own clients", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/oauth2/create-client", @app)
    client = json(conn)
    assert %{"client_id" => client_id, "client_secret" => secret} = client
    assert client["token_endpoint_auth_method"] == "client_secret_basic"
    assert client["require_pkce"] == true

    {browser, conn} = get(browser, "/oauth2/get-clients")
    assert [%{"client_id" => ^client_id} = listed] = json(conn)
    refute Map.has_key?(listed, "client_secret")

    {browser, conn} =
      post(browser, "/oauth2/update-client", %{
        client_id: client_id,
        update: %{"client_name" => "Renamed", "skip_consent" => true}
      })

    assert json(conn)["client_name"] == "Renamed"

    {browser, conn} = post(browser, "/oauth2/client/rotate-secret", %{client_id: client_id})
    assert json(conn)["client_secret"] != secret

    # Someone else sees nothing of it.
    {other, _user} = sign_up(Browser.new(Auth), %{email: "bob@example.com"})
    {other, conn} = get(other, "/oauth2/get-client", %{client_id: client_id})
    assert conn.status == 404
    {_other, conn} = post(other, "/oauth2/delete-client", %{client_id: client_id})
    assert conn.status == 404

    # A consent page may show the public parts to anyone.
    {_anyone, conn} = get(Browser.new(Auth), "/oauth2/public-client", %{client_id: client_id})
    assert json(conn)["client_name"] == "Renamed"
    refute Map.has_key?(json(conn), "redirect_uris")

    {browser, conn} = post(browser, "/oauth2/delete-client", %{client_id: client_id})
    assert json(conn) == %{"success" => true}
    {_browser, conn} = get(browser, "/oauth2/get-client", %{client_id: client_id})
    assert conn.status == 404
  end

  test "registration metadata is checked", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    for {metadata, code} <- [
          {%{"redirect_uris" => ["http://app.example/callback"]}, "invalid_redirect_uri"},
          {%{"redirect_uris" => ["javascript:alert(1)"]}, "invalid_redirect_uri"},
          {%{"redirect_uris" => ["https://app.example/cb#frag"]}, "invalid_redirect_uri"},
          {%{"redirect_uris" => []}, "invalid_redirect_uri"},
          {%{"redirect_uris" => ["https://a.example/cb"], "scope" => "openid admin"},
           "invalid_client_metadata"},
          {%{"redirect_uris" => ["https://a.example/cb"], "grant_types" => ["password"]},
           "invalid_client_metadata"},
          {%{
             "redirect_uris" => ["https://a.example/cb"],
             "token_endpoint_auth_method" => "none",
             "grant_types" => ["client_credentials"]
           }, "invalid_client_metadata"},
          {%{"redirect_uris" => ["myapp:/cb"]}, "invalid_redirect_uri"}
        ] do
      {_browser, conn} = post(browser, "/oauth2/create-client", metadata)
      assert json(conn)["error"]["code"] == code, inspect(metadata)
    end
  end

  test "anyone may register public clients, and only those", %{browser: browser} do
    {_client, conn} =
      post(%{browser | origin: nil}, "/oauth2/register", %{
        "client_name" => "MCP client",
        "redirect_uris" => ["http://localhost:6274/callback"]
      })

    assert conn.status == 201
    registered = json(conn)
    assert registered["token_endpoint_auth_method"] == "none"
    refute Map.has_key?(registered, "client_secret")

    {_client, conn} =
      post(%{browser | origin: nil}, "/oauth2/register", %{
        "redirect_uris" => ["https://app.example/cb"],
        "token_endpoint_auth_method" => "client_secret_basic"
      })

    assert json(conn)["error"] == "invalid_client_metadata"

    # Clients can't make themselves trusted.
    {_client, conn} =
      post(%{browser | origin: nil}, "/oauth2/register", %{
        "redirect_uris" => ["https://app.example/cb"],
        "skip_consent" => true
      })

    ctx = Authmk.Context.new(Auth.config())
    client_id = json(conn)["client_id"]
    assert %{skip_consent: false} = Authmk.Store.get_by(ctx, :oauth_client, client_id: client_id)
  end

  @tag auth: SignedInOnlyAuth
  test "registration needs a session there, and privileges decide", %{browser: browser} do
    {_client, conn} = post(%{browser | origin: nil}, "/oauth2/register", @app)
    assert conn.status == 401
    assert json(conn)["error"] == "invalid_token"

    {browser, _user} = sign_up(browser)
    {_browser, conn} = post(browser, "/oauth2/register", @app)
    assert json(conn)["client_secret"]

    {_browser, conn} = post(browser, "/oauth2/create-client", @app)
    assert conn.status == 403

    {admin, _user} = sign_up(Browser.new(SignedInOnlyAuth), %{email: "admin@example.com"})
    {_admin, conn} = post(admin, "/oauth2/create-client", @app)
    assert json(conn)["client_id"]
  end

  test "server code registers first-party clients" do
    assert {:ok, %{client_id: _, client_secret: _}} =
             OAuthProvider.create_client(Auth, @app, skip_consent: true)

    assert {:error, %{code: :invalid_redirect_uri}} =
             OAuthProvider.create_client(Auth, %{"redirect_uris" => ["ftp://x"]})
  end
end
