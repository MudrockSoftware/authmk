defmodule Authmk.DashboardTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.{Context, Store, Testing}
  alias Authmk.Plugins.Organization

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
        Authmk.Plugins.TwoFactor,
        Authmk.Plugins.Organization,
        Authmk.Plugins.AuditLog,
        Authmk.Plugins.SSO,
        Authmk.Plugins.SCIM
      ]
  end

  @moduletag auth: Auth

  # The app forwards /admin to the dashboard.
  defp dashboard(method, path, user \\ nil, headers \\ []) do
    conn = Plug.Test.conn(method, "/admin" <> path)
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    conn = if user, do: Testing.sign_in(conn, Auth, user), else: conn
    segments = conn.path_info |> tl()
    Plug.forward(conn, segments, Authmk.Dashboard, Authmk.Dashboard.init(auth: Auth))
  end

  defp api(method, path, user, headers \\ []),
    do: dashboard(method, "/api/" <> path, user, headers)

  defp from_dashboard, do: [{"origin", "http://localhost:4000"}]

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", name: "Admin", role: "admin")}
  end

  test "the app's page is for admins only", %{admin: admin} do
    assert dashboard(:get, "/").status == 302
    assert Plug.Conn.get_resp_header(dashboard(:get, "/"), "location") == ["/"]

    user = Testing.create_user(Auth, email: "ada@example.com")
    assert Plug.Conn.get_resp_header(dashboard(:get, "/", user), "location") == ["/"]

    # Relative links need the trailing slash.
    assert Plug.Conn.get_resp_header(dashboard(:get, ""), "location") == ["/admin/"]

    conn = dashboard(:get, "/", admin)
    assert conn.status == 200
    assert conn.resp_body =~ ~s("./_app/immutable/entry/start.)
    refute conn.resp_body =~ ~s("/_app/)
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    # Its files, wherever it's mounted.
    [_, start] = Regex.run(~r{"\./(_app/immutable/entry/start\.[^"]+)"}, conn.resp_body)
    asset = dashboard(:get, "/" <> start)
    assert asset.status == 200
    assert asset.resp_body =~ "import"
    assert dashboard(:get, "/_app/missing.js").status == 404
    assert dashboard(:get, "/elsewhere").status == 404
  end

  test "the API answers admins only", %{admin: admin} do
    assert api(:get, "me", nil).status == 401
    user = Testing.create_user(Auth, email: "ada@example.com")
    assert api(:get, "me", user).status == 403

    me = JSON.decode!(api(:get, "me", admin).resp_body)
    assert me["user"]["email"] == "admin@example.com"
    assert me["can"] == %{"ban" => true, "revoke_sessions" => true, "update_users" => true}
    assert me["features"]["organizations"] and me["features"]["audit_log"]
  end

  test "overview, users and their details", %{admin: admin} do
    ada =
      Testing.create_user(Auth, email: "ada@example.com", name: "Ada", password: "correct horse")

    Testing.create_user(Auth, email: "grace@example.com", name: "Grace")
    %{session: session} = Testing.create_session(Auth, ada)

    overview = JSON.decode!(api(:get, "overview", admin).resp_body)
    assert overview["totals"]["users"] == 3
    assert length(overview["sign_ups"]) == 30
    assert List.last(overview["sign_ups"])["count"] == 3
    assert %{"provider" => "credential", "count" => 1} in overview["sign_in_methods"]

    %{"users" => users, "has_more" => false} =
      JSON.decode!(api(:get, "users?search=ADA", admin).resp_body)

    assert [%{"email" => "ada@example.com"}] = users

    detail = JSON.decode!(api(:get, "users/#{ada.id}", admin).resp_body)
    assert [%{"id" => session_id}] = detail["sessions"]
    assert session_id == to_string(session.id)
    assert [%{"provider" => "credential"}] = detail["accounts"]
    assert Enum.any?(detail["events"], &(&1["event"] == "user.created"))

    assert api(:get, "users/not-a-user", admin).status == 404
  end

  test "actions, with the Origin and the permission checked", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com")
    Testing.create_session(Auth, ada)

    {:ok, _ada} =
      Store.update(Context.new(Auth.config()), :user, ada, %{two_factor_enabled: true})

    # Without the dashboard's Origin: refused (CSRF).
    assert api(:post, "users/#{ada.id}/ban", admin).status == 403

    assert api(:post, "users/#{ada.id}/disable-two-factor", admin, from_dashboard()).status == 200
    refute Testing.get_user_by(Auth, email: "ada@example.com").two_factor_enabled

    assert api(:post, "users/#{ada.id}/revoke-sessions", admin, from_dashboard()).status == 200
    assert Testing.list_sessions(Auth, ada) == []

    %{session: session} = Testing.create_session(Auth, ada)

    assert api(:post, "users/#{ada.id}/sessions/#{session.id}/revoke", admin, from_dashboard()).status ==
             200

    assert Testing.list_sessions(Auth, ada) == []

    assert api(:post, "users/#{ada.id}/ban", admin, from_dashboard()).status == 200
    assert Testing.get_user_by(Auth, email: "ada@example.com").banned
    assert api(:post, "users/#{ada.id}/unban", admin, from_dashboard()).status == 200
    refute Testing.get_user_by(Auth, email: "ada@example.com").banned

    assert api(:post, "users/#{ada.id}/delete-everything", admin, from_dashboard()).status == 404
  end

  test "organizations, SSO and the audit log", %{admin: admin} do
    {:ok, organization} =
      Store.insert(Context.new(Auth.config()), :organization, %{name: "Acme", slug: "acme"})

    {:ok, _member} = Organization.add_member(Auth, organization.id, admin.id, "owner")

    %{"organizations" => [listed]} = JSON.decode!(api(:get, "organizations", admin).resp_body)
    assert %{"name" => "Acme", "members" => 1} = listed

    detail = JSON.decode!(api(:get, "organizations/#{organization.id}", admin).resp_body)
    assert [%{"role" => "owner", "user" => %{"email" => "admin@example.com"}}] = detail["members"]
    assert api(:get, "organizations/nope", admin).status == 404

    assert %{"providers" => [], "connections" => []} =
             JSON.decode!(api(:get, "sso", admin).resp_body)

    events = JSON.decode!(api(:get, "events?event=member.added", admin).resp_body)
    assert [%{"event" => "member.added"}] = events["events"]
    assert events["total"] == 1
  end
end
