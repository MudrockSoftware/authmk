defmodule Authmk.APIClientsTest do
  # authmk's JSON API from apps that aren't pages on its own site: SPAs and
  # desktop webviews on other origins (CORS with credentials), and mobile
  # apps signing in through the system browser (deep links).
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      trusted_origins: ["https://app.example.com", "tauri://localhost", "myapp://"],
      cors: [trusted_origins: true],
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Bearer,
        {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2},
        {Authmk.Plugins.OneTimeToken, deep_links: ["myapp://"], disable_set_session_cookie: true}
      ]

    def send_magic_link(%{url: url}, _ctx), do: send(self(), {:magic_link, url})
  end

  @moduletag auth: Auth

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  test "trusted origins read answers, with credentials; others don't" do
    for origin <- ["https://app.example.com", "tauri://localhost"] do
      {_browser, conn} =
        post(Browser.new(Auth, origin: origin), "/sign-up/email", %{
          email: "ada-#{System.unique_integer([:positive])}@example.com",
          password: "correct horse battery",
          name: "Ada"
        })

      assert conn.status == 200
      assert header(conn, "access-control-allow-origin") == [origin]
      assert header(conn, "access-control-allow-credentials") == ["true"]
      assert [exposed] = header(conn, "access-control-expose-headers")
      assert exposed =~ "set-auth-token"
      assert header(conn, "vary") == ["origin"]
    end

    # An untrusted origin is refused, and gets no CORS headers to read why.
    {_browser, conn} =
      post(Browser.new(Auth, origin: "https://evil.example"), "/sign-in/email", %{
        email: "ada@example.com",
        password: "x"
      })

    assert conn.status == 403
    assert header(conn, "access-control-allow-origin") == []
  end

  test "preflight: for trusted origins, any endpoint; for others, none" do
    preflight = fn origin ->
      Plug.Test.conn(:options, "/auth/sign-in/email")
      |> Plug.Conn.put_req_header("origin", origin)
      |> Plug.Conn.put_req_header("access-control-request-method", "POST")
      |> then(&Plug.forward(&1, ["sign-in", "email"], Auth, Auth.init([])))
    end

    trusted = preflight.("https://app.example.com")
    assert trusted.status == 204
    assert header(trusted, "access-control-allow-origin") == ["https://app.example.com"]
    assert header(trusted, "access-control-allow-credentials") == ["true"]
    assert [methods] = header(trusted, "access-control-allow-methods")
    assert methods =~ "POST"

    untrusted = preflight.("https://evil.example")
    assert untrusted.status == 404
    assert header(untrusted, "access-control-allow-origin") == []
  end

  test "a mobile app's sign-in ends at its deep link with a one-time token", %{browser: browser} do
    {_browser, _user} = sign_up(browser, %{email: "ada@example.com"})

    # In the system browser: a magic link, back to the app.
    system_browser = Browser.new(Auth)

    {system_browser, _conn} =
      post(system_browser, "/sign-in/magic-link", %{
        email: "ada@example.com",
        callback_url: "myapp://signed-in"
      })

    assert_received {:magic_link, url}
    %URI{path: "/auth" <> path, query: query} = URI.parse(url)
    {_system_browser, conn} = get(system_browser, path, URI.decode_query(query))

    "myapp://signed-in?token=" <> token = redirected_to(conn)

    # The app trades it for a bearer token of its own, once.
    app = Browser.new(Auth, origin: nil)
    {app, conn} = post(app, "/one-time-token/verify", %{token: token})
    assert %{"token" => bearer, "user" => %{"email" => "ada@example.com"}} = json(conn)

    {app, conn} = post(app, "/one-time-token/verify", %{token: token})
    assert json(conn)["error"]["code"] == "invalid_token"

    with_bearer = %{app | headers: [{"authorization", "Bearer " <> bearer}]}
    {_app, conn} = get(with_bearer, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # Redirects elsewhere get no token.
    {system_browser, _conn} =
      post(system_browser, "/sign-in/magic-link", %{
        email: "ada@example.com",
        callback_url: "/web"
      })

    assert_received {:magic_link, url}
    %URI{path: "/auth" <> path, query: query} = URI.parse(url)
    {_system_browser, conn} = get(system_browser, path, URI.decode_query(query))
    assert redirected_to(conn) == "/web"
  end
end
