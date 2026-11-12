defmodule Authmk.DashboardAccessTest do
  # What an organization's roles grant (Authmk.Plugins.Gate), changed from
  # the dashboard by an app admin who isn't a member: within the abilities
  # the code declares, never app-only ones, and every change audited.
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.Plugins.{Gate, Organization}
  alias Authmk.Testing

  # Support staff may look users up, so the code lets them into the
  # dashboard; nothing else.
  defmodule Permissions do
    alias Authmk.Plugins.Admin.Permissions, as: AdminPermissions

    use Authmk.AccessControl,
      statements: AdminPermissions.statements(),
      roles: [
        admin: Authmk.AccessControl.role(AdminPermissions.access_control(), :admin),
        support: [user: [:list, :get]],
        user: []
      ]
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Admin, access_control: Authmk.DashboardAccessTest.Permissions},
        Authmk.Plugins.AuditLog,
        {Authmk.Plugins.Organization, teams: [enabled: true]},
        {Authmk.Plugins.Gate,
         abilities: [invoice: [:view, :update], billing: [:refund]],
         team_roles: [finance: [invoice: [:view, :update]]],
         team_member_roles: [employee: [invoice: [:view]]],
         app_only: [billing: [:refund]]}
      ]
  end

  defmodule NoGateAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        {Authmk.Plugins.Organization, teams: [enabled: true]}
      ]
  end

  describe "with the Gate plugin" do
    @describetag auth: Auth

    setup do
      admin = Testing.create_user(Auth, email: "admin@example.com", role: "admin")
      ada = Testing.create_user(Auth, email: "ada@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada.id)
      {:ok, team} = Organization.create_team(Auth, org.id, %{name: "Finance"})
      %{admin: admin, org: org, team: team}
    end

    test "roles, team roles and member roles, edited and audited", %{
      admin: admin,
      org: org,
      team: team
    } do
      grace = Testing.create_user(Auth, email: "grace@example.com")
      {:ok, _member} = Organization.add_member(Auth, org.id, grace.id, "member")
      {:ok, _team_member} = Organization.add_team_member(Auth, team.id, grace.id)

      {200, me} = get_json(Auth, "me", admin)
      assert me["features"]["gate"] == true

      {200, detail} = get_json(Auth, "organizations/#{org.id}", admin)
      assert detail["access"]["abilities"] == %{"invoice" => ["update", "view"]}

      assert %{"level" => "team", "role" => "finance", "source" => "code"} in Enum.map(
               detail["access"]["roles"],
               &Map.delete(&1, "permission")
             )

      # The team gets its role, Grace hers inside it.
      path = "organizations/#{org.id}/teams/#{team.id}"
      assert {200, _} = post_json(Auth, path <> "/role", admin, %{role: "finance"})

      assert {200, _} =
               post_json(Auth, "#{path}/members/#{grace.id}/role", admin, %{role: "employee"})

      assert {422, _} = post_json(Auth, path <> "/role", admin, %{role: "wizard"})
      assert {400, _} = post_json(Auth, path <> "/role", admin, %{role: ["finance"]})

      {200, detail} = get_json(Auth, "organizations/#{org.id}", admin)
      assert [%{"role" => "finance", "members" => [%{"role" => "employee"}]}] = detail["teams"]
      assert Gate.allows?(Auth, grace, {:invoice, :view}, %{organization_id: org.id})

      # Acme's own role, and an override; never an app-only ability.
      roles = "organizations/#{org.id}/access/roles"

      assert {200, _} =
               post_json(Auth, roles, admin, %{
                 level: "team_member",
                 role: "reviewer",
                 permission: %{invoice: ["view", "update"]}
               })

      assert {200, _} =
               post_json(Auth, roles, admin, %{
                 level: "team_member",
                 role: "employee",
                 permission: %{}
               })

      refute Gate.allows?(Auth, grace, {:invoice, :view}, %{organization_id: org.id})

      assert {422, %{"error" => %{"code" => "invalid_permission"}}} =
               post_json(Auth, roles, admin, %{
                 level: "team",
                 role: "finance",
                 permission: %{billing: ["refund"]}
               })

      assert {422, _} = post_json(Auth, roles, admin, %{level: 3, role: nil, permission: %{}})

      assert {200, _} =
               post_json(Auth, roles <> "/delete", admin, %{
                 level: "team_member",
                 role: "employee"
               })

      assert Gate.allows?(Auth, grace, {:invoice, :view}, %{organization_id: org.id})

      # The user's page shows what Gate lets them do, and through which team.
      {200, user} = get_json(Auth, "users/#{grace.id}", admin)
      [acme] = user["access"]["organizations"]
      assert acme["abilities"] == %{"invoice" => ["view"]}

      assert [%{"name" => "Finance", "role" => "finance", "member_role" => "employee"}] =
               acme["teams"]

      assert user["access"]["app"]["abilities"] == %{}

      events = Enum.map(dashboard_events(Auth), & &1.event)

      for event <- ~w(team.role_set team_member.role_set access_role.set access_role.deleted) do
        assert "dashboard.#{event}" in events
      end
    end

    test "only app admins and roles the code lets in use the dashboard", %{org: org, team: team} do
      path = "organizations/#{org.id}/teams/#{team.id}/role"

      # Acme's owner may do everything in Acme, but isn't an app admin.
      owner = Testing.get_user_by(Auth, email: "ada@example.com")
      assert {403, _} = get_json(Auth, "me", owner)
      assert {403, _} = post_json(Auth, path, owner, %{role: "finance"})

      # Support staff get in, because the code says so, and change nothing.
      support = Testing.create_user(Auth, email: "support@example.com", role: "support")
      {200, me} = get_json(Auth, "me", support)
      refute me["can"]["manage_organizations"]
      assert {403, _} = post_json(Auth, path, support, %{role: "finance"})
    end
  end

  describe "without the Gate plugin" do
    @describetag auth: NoGateAuth

    test "there is nothing to edit" do
      admin = Testing.create_user(NoGateAuth, email: "admin@example.com", role: "admin")
      ada = Testing.create_user(NoGateAuth, email: "ada@example.com")

      {:ok, org} =
        Organization.create_organization(NoGateAuth, %{name: "Acme", slug: "acme"}, ada.id)

      {:ok, team} = Organization.create_team(NoGateAuth, org.id, %{name: "Finance"})

      {200, me} = get_json(NoGateAuth, "me", admin)
      assert me["features"]["gate"] == false
      {200, detail} = get_json(NoGateAuth, "organizations/#{org.id}", admin)
      assert detail["access"] == nil

      assert {404, _} =
               post_json(NoGateAuth, "organizations/#{org.id}/access/roles", admin, %{
                 level: "team",
                 role: "x",
                 permission: %{}
               })

      assert {404, _} =
               post_json(NoGateAuth, "organizations/#{org.id}/teams/#{team.id}/role", admin, %{
                 role: "x"
               })
    end
  end
end
