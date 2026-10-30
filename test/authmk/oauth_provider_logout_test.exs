defmodule Authmk.OAuthProviderLogoutTest do
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
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in", consent_page: "/consent", logout_page: "/sign-out"}
      ]
  end

  @moduletag auth: Auth

  @redirect_uri "https://client.example/cb"

  setup do
    test = self()

    # The client's back-channel logout endpoint.
    Req.Test.stub(Auth, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:logout_token, conn.request_path, URI.decode_query(body)["logout_token"]})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    {:ok, client} =
      OAuthProvider.create_client(
        Auth,
        %{
          "redirect_uris" => [@redirect_uri],
          "post_logout_redirect_uris" => ["https://client.example/bye"],
          "backchannel_logout_uri" => "https://client.example/logout",
          "scope" => "openid"
        },
        skip_consent: true
      )

    %{client: client}
  end

  # Signs in to the client: returns the browser and the client's tokens.
  defp sign_in_to_client(browser, client) do
    {browser, _user} = sign_up(browser)
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: client.client_id,
        redirect_uri: @redirect_uri,
        scope: "openid",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    code = URI.decode_query(URI.parse(redirected_to(conn)).query)["code"]
    credentials = Base.encode64(client.client_id <> ":" <> client.client_secret)

    server = %{
      Browser.new(Auth)
      | origin: nil,
        headers: [{"authorization", "Basic " <> credentials}]
    }

    {_server, conn} =
      post(server, "/oauth2/token", %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        code_verifier: verifier
      })

    {browser, json(conn)}
  end

  defp signed_in?(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn) != nil
  end

  test "signing out tells the client, and ends its access tokens", %{
    browser: browser,
    client: client
  } do
    {browser, tokens} = sign_in_to_client(browser, client)
    sid = JOSE.JWT.peek_payload(tokens["id_token"]).fields["sid"]

    {_browser, _conn} = post(browser, "/sign-out")

    assert_received {:logout_token, "/logout", logout_token}
    {_browser, conn} = get(Browser.new(Auth), "/jwks")
    [key] = json(conn)["keys"]

    assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: header}} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["EdDSA"], logout_token)

    assert header["typ"] == "logout+jwt"
    assert claims["aud"] == client.client_id
    assert claims["sid"] == sid
    assert Map.has_key?(claims["events"], "http://schemas.openid.net/event/backchannel-logout")
    refute Map.has_key?(claims, "nonce")

    assert {:error, %{code: :invalid_token}} =
             OAuthProvider.verify_access_token(Auth, tokens["access_token"])
  end

  test "end-session with the session's ID token signs out at once", %{
    browser: browser,
    client: client
  } do
    {browser, tokens} = sign_in_to_client(browser, client)

    {browser, conn} =
      get(browser, "/oauth2/end-session", %{
        id_token_hint: tokens["id_token"],
        post_logout_redirect_uri: "https://client.example/bye",
        state: "s"
      })

    assert redirected_to(conn) == "https://client.example/bye?state=s"
    refute signed_in?(browser)
    assert_received {:logout_token, "/logout", _token}
  end

  test "without it, the user confirms first", %{browser: browser, client: client} do
    {browser, _tokens} = sign_in_to_client(browser, client)

    {browser, conn} =
      get(browser, "/oauth2/end-session", %{
        client_id: client.client_id,
        post_logout_redirect_uri: "https://client.example/bye"
      })

    page = redirected_to(conn)
    assert "http://localhost:4000/sign-out?" <> _ = page
    # Following a link alone doesn't sign out.
    assert signed_in?(browser)

    logout_query = URI.decode_query(URI.parse(page).query)["logout_query"]

    {browser, conn} =
      post(browser, "/oauth2/end-session/confirm", %{logout_query: logout_query <> "x"})

    assert json(conn)["error"]["code"] == "invalid_logout_query"

    {browser, conn} = post(browser, "/oauth2/end-session/confirm", %{logout_query: logout_query})
    assert json(conn)["url"] == "https://client.example/bye"
    refute signed_in?(browser)
  end

  test "only registered places to go back to", %{browser: browser, client: client} do
    {browser, tokens} = sign_in_to_client(browser, client)

    {browser, conn} =
      get(browser, "/oauth2/end-session", %{
        id_token_hint: tokens["id_token"],
        post_logout_redirect_uri: "https://evil.example/"
      })

    assert redirected_to(conn) =~ "http://localhost:4000/auth/error?"
    assert signed_in?(browser)

    # An ID token from another client doesn't name this one.
    {:ok, other} = OAuthProvider.create_client(Auth, %{"redirect_uris" => [@redirect_uri]})

    {_browser, conn} =
      get(browser, "/oauth2/end-session", %{
        id_token_hint: tokens["id_token"],
        client_id: other.client_id
      })

    assert redirected_to(conn) =~
             "error_description=The%20ID%20token%20was%20issued%20to%20another%20client"
  end
end
