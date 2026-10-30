defmodule Authmk.DashboardTest do
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.{Context, Store, Testing}
  alias Authmk.Plugins.{Organization, SCIM}

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
        {Authmk.Plugins.Organization, teams: [enabled: true]},
        Authmk.Plugins.AuditLog,
        Authmk.Plugins.SSO,
        Authmk.Plugins.SCIM,
        Authmk.Plugins.APIKey,
        Authmk.Plugins.ServiceAccount
      ]
  end

  @moduletag auth: Auth

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", name: "Admin", role: "admin")}
  end

  test "the app's page is for admins only", %{admin: admin} do
    assert dashboard(Auth, :get, "/").status == 302
    assert Plug.Conn.get_resp_header(dashboard(Auth, :get, "/"), "location") == ["/"]

    user = Testing.create_user(Auth, email: "ada@example.com")
    assert Plug.Conn.get_resp_header(dashboard(Auth, :get, "/", user), "location") == ["/"]

    # Relative links need the trailing slash.
    assert Plug.Conn.get_resp_header(dashboard(Auth, :get, ""), "location") == ["/admin/"]

    conn = dashboard(Auth, :get, "/", admin)
    assert conn.status == 200
    assert conn.resp_body =~ ~s("./_app/immutable/entry/start.)
    refute conn.resp_body =~ ~s("/_app/)
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    # Its files, wherever it's mounted.
    [_, start] = Regex.run(~r{"\./(_app/immutable/entry/start\.[^"]+)"}, conn.resp_body)
    asset = dashboard(Auth, :get, "/" <> start)
    assert asset.status == 200
    assert asset.resp_body =~ "import"
    assert dashboard(Auth, :get, "/_app/missing.js").status == 404
    assert dashboard(Auth, :get, "/elsewhere").status == 404
  end

  test "the API answers admins only, and says what they may do", %{admin: admin} do
    assert api(Auth, :get, "me", nil).status == 401
    user = Testing.create_user(Auth, email: "ada@example.com")
    assert api(Auth, :get, "me", user).status == 403

    {200, me} = get_json(Auth, "me", admin)
    assert me["user"]["email"] == "admin@example.com"
    assert me["roles"] == ["admin", "user"]
    assert Enum.all?(Map.values(me["can"]))

    assert %{"service_accounts" => true, "organizations" => true, "teams" => true} =
             me["features"]

    assert %{"audit_log" => true, "payments" => false, "branding" => false} = me["features"]
  end

  test "changes need the dashboard's Origin", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com")
    conn = api(Auth, :post, "users/#{ada.id}/ban", admin, origin: false)
    assert conn.status == 403
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "invalid_origin"
    refute Testing.get_user_by(Auth, email: "ada@example.com").banned

    # An unreadable body is refused.
    conn =
      Plug.Test.conn(:post, "/admin/api/users/#{ada.id}/ban", "{not json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost:4000")
      |> Testing.sign_in(Auth, admin)

    conn =
      Plug.forward(conn, tl(conn.path_info), Authmk.Dashboard, Authmk.Dashboard.init(auth: Auth))

    assert conn.status == 400
  end

  test "overview, users and what a user can see and do", %{admin: admin} do
    ada =
      Testing.create_user(Auth, email: "ada@example.com", name: "Ada", password: "correct horse")

    Testing.create_user(Auth, email: "grace@example.com", name: "Grace")
    %{session: session} = Testing.create_session(Auth, ada)

    {200, overview} = get_json(Auth, "overview", admin)
    assert overview["totals"]["users"] == 3
    assert length(overview["sign_ups"]) == 30
    assert List.last(overview["sign_ups"])["count"] == 3
    assert %{"provider" => "credential", "count" => 1} in overview["sign_in_methods"]

    {200, %{"users" => users, "has_more" => false}} = get_json(Auth, "users?search=ADA", admin)
    assert [%{"email" => "ada@example.com"}] = users

    ctx = Context.new(Auth.config())
    {:ok, acme} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada.id)
    {:ok, team} = Organization.create_team(Auth, acme.id, %{name: "Platform"})
    {:ok, _member} = Organization.add_team_member(Auth, team.id, ada.id)
    {:ok, _key} = Store.insert(ctx, :api_key, %{name: "CI", key: "hashed", user_id: ada.id})

    {200, detail} = get_json(Auth, "users/#{ada.id}", admin)
    assert [%{"id" => session_id}] = detail["sessions"]
    assert session_id == to_string(session.id)
    assert [%{"provider" => "credential"}] = detail["accounts"]
    assert [%{"name" => "CI", "enabled" => true}] = detail["api_keys"]
    refute Map.has_key?(hd(detail["api_keys"]), "key")
    assert %{"enabled" => false, "authenticator_app" => false} = detail["two_factor"]
    assert Enum.any?(detail["events"], &(&1["event"] == "user.created"))

    # Roles and where their permissions come from.
    assert %{"roles" => [%{"name" => "user", "source" => "app role"}]} = detail["access"]["app"]
    [acme_access] = detail["access"]["organizations"]
    assert %{"name" => "Acme", "teams" => [%{"name" => "Platform"}]} = acme_access

    assert [%{"name" => "owner", "source" => "built-in role", "permissions" => grants}] =
             acme_access["roles"]

    assert "delete" in grants["organization"]

    # Search by status, and by organization.
    {200, %{"users" => [%{"email" => "ada@example.com"}]}} =
      get_json(Auth, "users?organization_id=#{acme.id}", admin)

    {200, %{"users" => []}} = get_json(Auth, "users?organization_id=nope", admin)

    {:ok, _ada} =
      Store.update(ctx, :user, ada, %{
        banned: true,
        two_factor_enabled: true,
        email_verified: false
      })

    {200, %{"users" => [%{"email" => "ada@example.com"}]}} =
      get_json(Auth, "users?status=banned", admin)

    {200, %{"users" => [%{"email" => "ada@example.com"}]}} =
      get_json(Auth, "users?status=two_factor", admin)

    {200, %{"users" => [%{"email" => "ada@example.com"}]}} =
      get_json(Auth, "users?status=unverified", admin)

    assert api(Auth, :get, "users/not-a-user", admin).status == 404
  end

  test "SSO, the audit log and service accounts", %{admin: admin} do
    assert {200, %{"providers" => [], "connections" => []}} = get_json(Auth, "sso", admin)

    # A directory that hasn't called yet is worth a look.
    {:ok, acme} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, admin.id)

    {:ok, _connection} =
      SCIM.create_connection(Auth,
        organization_id: to_string(acme.id),
        name: "Okta"
      )

    {200, %{"checks" => checks}} = get_json(Auth, "health", admin)

    assert %{"status" => "warning", "area" => "SCIM"} =
             Enum.find(checks, &(&1["name"] == "SCIM: Okta"))

    assert {200, %{"connections" => [%{"name" => "Okta"}]}} = get_json(Auth, "sso", admin)

    {:ok, account} =
      Store.insert(Context.new(Auth.config()), :service_account, %{
        name: "Nightly export",
        user_id: admin.id,
        last_used_at: DateTime.utc_now()
      })

    {200, overview} = get_json(Auth, "overview", admin)
    assert overview["totals"]["users"] == 1
    assert overview["totals"]["service_accounts"] == 1
    assert overview["totals"]["active_service_accounts"] == 1

    {200, %{"service_accounts" => [listed]}} = get_json(Auth, "service-accounts", admin)
    assert %{"name" => "Nightly export", "disabled" => false, "oauth_client" => false} = listed

    path = "service-accounts/#{account.id}"
    assert api(Auth, :post, path <> "/disable", admin, origin: false).status == 403
    assert {200, _} = post_json(Auth, path <> "/disable", admin)
    assert Store.get_by(Context.new(Auth.config()), :service_account, id: account.id).disabled

    assert {200, _} = post_json(Auth, path <> "/delete", admin)
    assert Store.get_by(Context.new(Auth.config()), :service_account, id: account.id) == nil
    assert {404, _} = post_json(Auth, path <> "/enable", admin)

    {200, events} = get_json(Auth, "events?event=dashboard.service_account.disabled", admin)
    assert [%{"actor_id" => actor}] = events["events"]
    assert actor == to_string(admin.id)
  end
end
