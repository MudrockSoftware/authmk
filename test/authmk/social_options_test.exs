defmodule Authmk.SocialOptionsTest do
  # Provider options every built-in provider takes, and the ID token from
  # the code exchange.
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        google: [
          client_id: "google-id",
          token_auth: :none,
          audience: ["com.example.ios"],
          access_token_expires_in: 120,
          authorize_params: %{"login_hint" => "ada@example.com", "state" => "forged"}
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://accounts.google.com",
        "aud" => "google-id",
        "sub" => "g-1",
        "email" => "ada@example.com",
        "email_verified" => true,
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  defp start(browser) do
    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "google", callback_url: "/done"})

    url = json(conn)["url"]
    {browser, url, URI.decode_query(URI.parse(url).query)}
  end

  # Signs in with the ID token `claims` from the token endpoint.
  defp sign_in(browser, claims_for_nonce) do
    {browser, url, query} = start(browser)

    FakeProvider.stub(
      Auth,
      FakeProvider.signed_id_token(claims_for_nonce.(query["nonce"]), "/oauth2/v3/certs") ++
        [expires_in: nil, public_client: true]
    )

    get(browser, "/callback/google", FakeProvider.approve(url))
  end

  test "the app's authorization params can't replace the standard ones", %{browser: browser} do
    {_browser, _url, query} = start(browser)

    assert query["login_hint"] == "ada@example.com"
    assert query["state"] != "forged"
  end

  test "a public client sends no secret", %{browser: browser} do
    test = self()

    token = fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:token_request, URI.decode_query(body), Plug.Conn.get_req_header(conn, "authorization")}
      )

      {400, %{"error" => "invalid_grant"}}
    end

    {browser, url, _query} = start(browser)
    FakeProvider.stub(Auth, routes: %{"/token" => token})
    get(browser, "/callback/google", FakeProvider.approve(url))

    assert_received {:token_request, form, []}
    assert form["client_id"] == "google-id"
    refute Map.has_key?(form, "client_secret")
  end

  test "the ID token from the code exchange must carry the request's nonce", %{browser: browser} do
    {_browser, conn} = sign_in(browser, &claims(%{"nonce" => &1 <> "-other"}))
    assert redirected_to(conn) =~ "error=invalid_id_token"
    assert Repo.aggregate("users", :count) == 0
  end

  test "with the request's nonce it signs in", %{browser: browser} do
    {_browser, conn} = sign_in(browser, &claims(%{"nonce" => &1}))
    assert redirected_to(conn) == "/done"
  end

  test "access_token_expires_in fills in a lifetime the provider didn't send", %{
    browser: browser
  } do
    {_browser, conn} = sign_in(browser, fn _nonce -> claims() end)
    assert redirected_to(conn) == "/done"

    [expires_at] = Repo.all(from(a in "accounts", select: a.access_token_expires_at))
    {:ok, expires_at} = Ecto.Type.cast(:utc_datetime, expires_at)
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 110..120
  end

  test "an ID token for another configured audience signs in", %{browser: browser} do
    {jwk, jwks} = FakeProvider.signing_key()
    FakeProvider.stub(Auth, jwks: jwks)
    token = FakeProvider.id_token(jwk, claims(%{"aud" => "com.example.ios"}))

    {_browser, conn} =
      post(browser, "/sign-in/social", %{provider: "google", id_token: %{token: token}})

    assert json(conn)["user"]["email"] == "ada@example.com"
  end
end

defmodule Authmk.JWKSCooldownTest do
  # Changes the application env, so not async.
  use Authmk.EmulationCase, async: false

  alias Authmk.Test.FakeProvider

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      social_providers: [google: [client_id: "google-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  setup do
    Application.put_env(:authmk, :jwks_refetch_cooldown, 30)
    on_exit(fn -> Application.put_env(:authmk, :jwks_refetch_cooldown, 0) end)
  end

  test "tokens with unknown key ids refetch the JWKS at most once in a while", %{
    browser: browser
  } do
    test = self()
    {jwk, jwks} = FakeProvider.signing_key()

    serve_jwks = fn _conn ->
      send(test, :jwks_fetched)
      jwks
    end

    FakeProvider.stub(Auth, public_routes: %{"/oauth2/v3/certs" => serve_jwks})
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "aud" => "google-id",
      "sub" => "g-1",
      "iat" => now,
      "exp" => now + 600
    }

    for kid <- ["made-up-1", "made-up-2", "made-up-3"] do
      token = FakeProvider.id_token(jwk, claims, %{"alg" => "RS256", "kid" => kid})

      {_browser, conn} =
        post(browser, "/sign-in/social", %{provider: "google", id_token: %{token: token}})

      assert json(conn)["error"]["code"] == "invalid_id_token"
    end

    # The first fetch, and one refetch for the unknown key; then the cooldown.
    assert_received :jwks_fetched
    assert_received :jwks_fetched
    refute_received :jwks_fetched
  end
end
