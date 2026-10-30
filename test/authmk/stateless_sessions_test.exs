defmodule Authmk.StatelessSessionsTest do
  # Sessions with no server-side storage: the encrypted cache cookie is the
  # session, refreshed as it's used, revoked by changing its version.
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      plugins: [Authmk.Plugins.EmailPassword],
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      session: [
        stateless: true,
        expires_in: 3600,
        update_age: 1,
        cookie_cache: [strategy: :encrypted, version: &__MODULE__.session_version/1]
      ]

    # Each user's version, as an app would keep it somewhere fast.
    def session_version(user),
      do: :persistent_term.get({__MODULE__, user.id}, "1")
  end

  @moduletag auth: Auth

  defp cache_cookie(browser),
    do: Enum.find_value(browser.cookies, fn {name, value} -> name =~ "session_data" and value end)

  test "signed in with no session stored anywhere", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    assert Repo.aggregate("sessions", :count) == 0

    {browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # Endpoints that need a session take it from the cookie too.
    {browser, conn} = post(browser, "/update-user", %{name: "Ada L."})
    assert json(conn)["user"]["name"] == "Ada L."
    {browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["name"] == "Ada L."

    {browser, _conn} = post(browser, "/sign-out")
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil
  end

  test "the cookie lasts as long as the session, and is refreshed as it's used", %{
    browser: browser
  } do
    {browser, _user} = sign_up(browser)
    first = cache_cookie(browser)

    Process.sleep(1100)
    {browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
    refute cache_cookie(browser) == first

    [cookie] = for {name, %{max_age: age}} <- conn.resp_cookies, name =~ "session_data", do: age
    assert cookie == 3600
  end

  test "changing a user's version signs out their sessions, and only theirs", %{browser: browser} do
    {ada, user} = sign_up(browser)
    {bob, _user} = sign_up(browser, %{email: "bob@example.com"})

    :persistent_term.put({Auth, user["id"]}, "2")
    on_exit(fn -> :persistent_term.erase({Auth, user["id"]}) end)

    {_ada, conn} = get(ada, "/get-session")
    assert json(conn) == nil
    {_bob, conn} = get(bob, "/get-session")
    assert json(conn)["user"]["email"] == "bob@example.com"
  end

  test "a changed or moved cookie signs nobody in", %{browser: browser} do
    {ada, _user} = sign_up(browser)
    {bob, _user} = sign_up(browser, %{email: "bob@example.com"})

    {name, value} = Enum.find(ada.cookies, fn {name, _} -> name =~ "session_data" end)

    {_browser, conn} =
      get(%{ada | cookies: Map.put(ada.cookies, name, value <> "x")}, "/get-session")

    assert json(conn) == nil

    # Ada's session in Bob's browser: bound to Ada's token, not Bob's.
    {_browser, conn} = get(%{bob | cookies: Map.put(bob.cookies, name, value)}, "/get-session")
    assert json(conn) == nil
  end

  test "LiveViews read the session from the cookie's value", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    conn =
      Enum.reduce(browser.cookies, Plug.Test.conn(:get, "/"), fn {name, value}, conn ->
        Plug.Test.put_req_cookie(conn, name, value)
      end)

    session = Authmk.LiveView.session(conn, Auth)
    assert is_binary(session["authmk_session_data"])

    {:cont, socket} =
      Authmk.LiveView.on_mount({:current_user, Auth}, %{}, session, %Phoenix.LiveView.Socket{})

    assert socket.assigns.current_user.email == "ada@example.com"
    assert socket.assigns.current_session.user.email == "ada@example.com"
  end
end
