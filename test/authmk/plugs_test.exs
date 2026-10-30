defmodule Authmk.PlugsTest do
  # The plugs and controller helpers an app puts in front of its own pages.
  use Authmk.EmulationCase, async: true

  import Plug.Conn

  alias Authmk.Phoenix.Controller
  alias Authmk.Plug.{FetchSession, RequireRole, RequireUser}
  alias Authmk.Testing

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        {Authmk.Plugins.APIKey, configurations: [default: [rate_limit: [enabled: false]]]},
        Authmk.Plugins.ServiceAccount,
        Authmk.Plugins.TwoFactor
      ]
  end

  @moduletag auth: Auth

  defp request(conn \\ Plug.Test.conn(:get, "/page"), plugs) do
    conn = FetchSession.call(conn, FetchSession.init(auth: Auth))

    Enum.reduce_while(plugs, conn, fn {plug, opts}, conn ->
      conn = plug.call(conn, plug.init(opts))
      if conn.halted, do: {:halt, conn}, else: {:cont, conn}
    end)
  end

  defp signed_in(user), do: Testing.sign_in(Plug.Test.conn(:get, "/page"), Auth, user)

  test "RequireUser: users only, not signed-out visitors or service accounts", %{
    browser: browser
  } do
    ada = Testing.create_user(Auth, email: "ada@example.com")

    assert request([{RequireUser, []}]).status == 401

    assert request([{RequireUser, redirect_to: "/sign-in"}]) |> get_resp_header("location") == [
             "/sign-in"
           ]

    refute request(signed_in(ada), [{RequireUser, []}]).halted

    # A service account's key authenticates it, but it isn't a user.
    {browser, _user} = sign_up(browser, %{email: "owner@example.com"})
    {browser, conn} = post(browser, "/service-account/create", %{name: "Robot"})
    {_browser, conn} = post(browser, "/service-account/create-key", %{id: json(conn)["id"]})
    robot = Plug.Test.conn(:get, "/page") |> put_req_header("x-api-key", json(conn)["key"])
    refute request(robot, [{Authmk.Plug.RequireAuthenticated, allow_principals: true}]).halted
    assert request(robot, [{RequireUser, []}]).status == 401
  end

  test "RequireRole: by role names, or by Admin permissions" do
    ada = Testing.create_user(Auth, email: "ada@example.com", role: "user")
    boss = Testing.create_user(Auth, email: "boss@example.com", role: "user,admin")

    assert request([{RequireRole, roles: ["admin"]}]).status == 401
    assert request(signed_in(ada), [{RequireRole, roles: ["admin"]}]).status == 403
    refute request(signed_in(boss), [{RequireRole, roles: ["admin", "support"]}]).halted

    can_ban = [auth: Auth, permissions: %{user: [:ban]}]
    assert request(signed_in(ada), [{RequireRole, can_ban}]).status == 403
    refute request(signed_in(boss), [{RequireRole, can_ban}]).halted

    assert request(signed_in(ada), [{RequireRole, roles: ["admin"], redirect_to: "/"}])
           |> get_resp_header("location") == ["/"]

    assert_raise ArgumentError, fn -> RequireRole.init([]) end

    assert_raise ArgumentError, fn ->
      RequireRole.init(roles: ["a"], permissions: %{}, auth: Auth)
    end
  end

  test "controller helpers: who's signed in, signing in and out from your code" do
    ada = Testing.create_user(Auth, email: "ada@example.com")
    conn = request([])
    refute Controller.signed_in?(conn)

    {:ok, conn} = Controller.sign_in(conn, Auth, ada)
    assert Controller.current_user(conn).id == ada.id
    assert Controller.current_principal(conn).id == ada.id
    assert [_session] = Testing.list_sessions(Auth, ada)

    # The cookie it set signs the next request in.
    next = Plug.Test.conn(:get, "/page") |> Plug.Test.recycle_cookies(conn) |> request([])
    assert Controller.current_session(next).user_id == ada.id

    out = Controller.sign_out(next, Auth)
    refute Controller.signed_in?(out)
    assert Testing.list_sessions(Auth, ada) == []
    assert out.resp_cookies |> Map.values() |> Enum.all?(&(&1[:max_age] == 0))
  end

  test "signing in from your code still asks for the second factor" do
    ada = Testing.create_user(Auth, email: "ada@example.com", two_factor_enabled: true)

    assert {:challenge, conn, %{two_factor_redirect: true}} =
             Controller.sign_in(request([]), Auth, ada)

    refute Controller.signed_in?(conn)
    assert Testing.list_sessions(Auth, ada) == []
  end
end
