defmodule Authmk.SessionsTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    session: [expires_in: 3600, update_age: 600]
end

defmodule Authmk.SessionsTest.DeferredAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    session: [expires_in: 3600, update_age: 600, defer_refresh: true]
end

defmodule Authmk.SessionsTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plug.{FetchSession, RequireAuthenticated}
  alias Authmk.SessionsTest.Auth
  alias Authmk.Test.Repo

  @moduletag auth: Auth

  test "lists the user's sessions without exposing tokens", %{browser: browser} do
    {laptop, _user} = sign_up(browser)

    {_phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {_laptop, conn} = get(laptop, "/list-sessions")
    sessions = json(conn)

    assert length(sessions) == 2
    assert Enum.all?(sessions, &(not Map.has_key?(&1, "token")))
  end

  test "the cookie holds the signed token; the database only its hash", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    signed = cookie(browser, "authmk.session_token")
    {:ok, token} = Authmk.Crypto.verify(Auth.config(), "session-token", signed)

    [stored] = Repo.all(from(s in "sessions", select: s.token))
    assert stored == Authmk.Token.hash(token)
    refute stored in [token, signed]
  end

  test "a cookie with a valid token but a forged signature is rejected", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    {:ok, token} =
      Authmk.Crypto.verify(
        Auth.config(),
        "session-token",
        cookie(browser, "authmk.session_token")
      )

    for forged <- [token, "v0." <> Base.url_encode64(token) <> "--forged"] do
      {browser, conn} =
        get(%{browser | cookies: %{"authmk.session_token" => forged}}, "/get-session")

      assert json(conn) == nil
      assert cookie(browser, "authmk.session_token") == nil
    end
  end

  test "revoking one session signs out only that device", %{browser: browser} do
    {laptop, _user} = sign_up(browser)

    {phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {_phone, conn} = get(phone, "/get-session")
    phone_session_id = json(conn)["session"]["id"]

    {_laptop, conn} = post(laptop, "/revoke-session", %{id: phone_session_id})
    assert json(conn) == %{"status" => true}

    {_phone, conn} = get(phone, "/get-session")
    assert json(conn) == nil
    {_laptop, conn} = get(laptop, "/get-session")
    assert json(conn)["user"]
  end

  test "a user can't revoke someone else's session", %{browser: browser} do
    {ada, _user} = sign_up(browser)
    {bob, _user} = sign_up(browser, %{email: "bob@example.com"})
    {_bob, conn} = get(bob, "/get-session")
    bob_session_id = json(conn)["session"]["id"]

    {_ada, _conn} = post(ada, "/revoke-session", %{id: bob_session_id})

    {_bob, conn} = get(bob, "/get-session")
    assert json(conn)["user"]["email"] == "bob@example.com"
  end

  test "revoke-sessions signs out everywhere, including here", %{browser: browser} do
    {laptop, _user} = sign_up(browser)

    {phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {laptop, _conn} = post(laptop, "/revoke-sessions")

    for device <- [laptop, phone] do
      {_device, conn} = get(device, "/get-session")
      assert json(conn) == nil
    end
  end

  test "revoke-other-sessions keeps the current one", %{browser: browser} do
    {laptop, _user} = sign_up(browser)

    {phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {laptop, _conn} = post(laptop, "/revoke-other-sessions")

    {_phone, conn} = get(phone, "/get-session")
    assert json(conn) == nil
    {_laptop, conn} = get(laptop, "/get-session")
    assert json(conn)["user"]
  end

  test "a session is extended once update_age has passed", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    # Pretend the session was last refreshed 11 minutes ago.
    eleven_minutes_ago = DateTime.add(DateTime.utc_now(), 3600 - 660)
    Repo.update_all("sessions", set: [expires_at: eleven_minutes_ago])

    {_browser, conn} = get(browser, "/get-session")
    expires_at = conn |> json() |> get_in(["session", "expires_at"]) |> parse_datetime()

    assert DateTime.diff(expires_at, DateTime.utc_now()) > 3500
    assert conn.resp_cookies["authmk.session_token"].max_age == 3600
  end

  describe "deferred refresh" do
    @describetag auth: Authmk.SessionsTest.DeferredAuth

    test "GET only reports that a refresh is due; POST does it", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      eleven_minutes_ago = DateTime.add(DateTime.utc_now(), 3600 - 660)
      Repo.update_all("sessions", set: [expires_at: eleven_minutes_ago])

      stored = fn -> Repo.all(from(s in "sessions", select: s.expires_at)) end
      before = stored.()

      {browser, conn} = get(browser, "/get-session")
      assert json(conn)["needs_refresh"] == true
      assert stored.() == before

      {browser, conn} = post(browser, "/get-session")
      refute json(conn)["needs_refresh"]
      {_browser, conn} = get(browser, "/get-session")
      refute json(conn)["needs_refresh"]
    end
  end

  test "a session isn't extended before update_age", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = get(browser, "/get-session")

    refute Map.has_key?(conn.resp_cookies, "authmk.session_token")
  end

  test "an expired session is rejected and its cookie cleared", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    Repo.update_all("sessions", set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

    {browser, conn} = get(browser, "/get-session")

    assert json(conn) == nil
    assert cookie(browser, "authmk.session_token") == nil
    assert Repo.aggregate("sessions", :count) == 0
  end

  test "an unknown session token clears the cookie", %{browser: browser} do
    browser = %{browser | cookies: %{"authmk.session_token" => "forged"}}
    {browser, conn} = get(browser, "/get-session")

    assert json(conn) == nil
    assert cookie(browser, "authmk.session_token") == nil
  end

  test "records IP address and user agent", %{browser: browser} do
    browser = %{browser | headers: [{"user-agent", "TestBrowser/1.0"}]}
    {browser, _user} = sign_up(browser)
    {_browser, conn} = get(browser, "/get-session")

    assert json(conn)["session"]["user_agent"] == "TestBrowser/1.0"
    assert json(conn)["session"]["ip_address"] == "127.0.0.1"
  end

  describe "Authmk.Plug.FetchSession" do
    test "assigns the current user and session", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      conn =
        Plug.Test.conn(:get, "/dashboard")
        |> Plug.Test.put_req_cookie(
          "authmk.session_token",
          cookie(browser, "authmk.session_token")
        )
        |> FetchSession.call(FetchSession.init(auth: Auth))

      assert conn.assigns.current_user.email == "ada@example.com"
      assert conn.assigns.current_session.user_id == conn.assigns.current_user.id
    end

    test "RequireAuthenticated rejects anonymous requests" do
      conn =
        Plug.Test.conn(:get, "/dashboard")
        |> FetchSession.call(FetchSession.init(auth: Auth))
        |> RequireAuthenticated.call(RequireAuthenticated.init([]))

      assert conn.halted
      assert conn.status == 401

      conn =
        Plug.Test.conn(:get, "/dashboard")
        |> FetchSession.call(FetchSession.init(auth: Auth))
        |> RequireAuthenticated.call(RequireAuthenticated.init(redirect_to: "/sign-in"))

      assert redirected_to(conn) == "/sign-in"
    end
  end

  defp parse_datetime(string) do
    {:ok, datetime, 0} = DateTime.from_iso8601(string)
    datetime
  end
end
