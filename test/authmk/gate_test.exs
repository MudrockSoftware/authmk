defmodule Authmk.GateTest do
  # Authorization with Authmk.Plugins.Gate: app roles alone, then
  # organizations, teams and roles inside teams, and organizations changing
  # their own access.
  use Authmk.EmulationCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Authmk.{Context, Credentials}
  alias Authmk.Plug.{FetchSession, RequireAbility}
  alias Authmk.Plugins.{AuditLog, Gate, Organization}
  alias Authmk.Test.{Browser, Repo}
  alias Authmk.Testing

  @password "correct horse battery"

  # The app's roles, for Authmk.Plugins.Admin: support staff may look
  # users up. What they may do in the app is the Gate's `app_roles`.
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

  defmodule AppAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Admin, access_control: Authmk.GateTest.Permissions},
        {Authmk.Plugins.Gate,
         abilities: [report: [:view, :export], billing: [:refund]],
         app_roles: [support: [report: [:view]]],
         app_only: [billing: [:refund]]}
      ]
  end

  defmodule OrgAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Admin, access_control: Authmk.GateTest.Permissions},
        {Authmk.Plugins.Organization, teams: [enabled: true]},
        {Authmk.Plugins.AuditLog, can_view_all: &__MODULE__.admin?/1},
        {Authmk.Plugins.Gate,
         abilities: [
           invoice: [:view, :update, :delete],
           report: [:view, :export],
           billing: [:refund]
         ],
         app_roles: [support: [invoice: [:view]]],
         organization_roles: [member: [report: [:view]]],
         team_roles: [
           finance: [invoice: [:view, :update, :delete]],
           analysts: [report: [:view, :export]]
         ],
         team_member_roles: [
           employee: [invoice: [:view], report: [:view]],
           manager: [invoice: [:view, :update], report: [:view, :export]]
         ],
         app_only: [billing: [:refund]],
         default_team_member_role: "employee"}
      ]

    def admin?(_ctx), do: false
  end

  # Signs in a new user and returns the browser and the user record.
  defp signed_in(auth, email, attrs \\ []) do
    user = Testing.create_user(auth, [email: email, password: @password] ++ attrs)

    {browser, conn} =
      post(Browser.new(auth), "/sign-in/email", %{email: email, password: @password})

    200 = conn.status
    {browser, user}
  end

  defp user(auth, email, attrs \\ []), do: Testing.create_user(auth, [email: email] ++ attrs)

  describe "with app roles only" do
    @describetag auth: AppAuth

    test "app roles grant what the code says, and admins everything" do
      {admin_browser, admin} = signed_in(AppAuth, "root@example.com", role: "admin")
      {ada_browser, ada} = signed_in(AppAuth, "ada@example.com")

      refute Gate.allows?(AppAuth, ada, {:report, :view})

      assert Gate.authorize(AppAuth, ada, {:report, :view}) ==
               {:error, Authmk.Error.new(:forbidden)}

      # An admin makes Ada support staff, through the Admin plugin.
      {admin_browser, conn} =
        post(admin_browser, "/admin/set-role", %{user_id: ada.id, role: "support"})

      assert conn.status == 200

      # The record Ada's code holds is stale; the check reads the database.
      assert Gate.allows?(AppAuth, ada, {:report, :view})
      assert Gate.authorize(AppAuth, ada, {"report", "view"}) == :ok
      refute Gate.allows?(AppAuth, ada, {:report, :export})
      refute Gate.allows?(AppAuth, ada, {:billing, :refund})
      assert Gate.abilities(AppAuth, ada) == %{"report" => ["view"]}

      {_ada_browser, conn} = get(ada_browser, "/gate/abilities")
      assert json(conn) == %{"abilities" => %{"report" => ["view"]}}

      # App admins may do everything, app-only abilities too.
      assert Gate.allows?(AppAuth, admin, {:billing, :refund})
      assert Gate.allows?(AppAuth, admin, {:report, :export})

      # Without organizations, organization ids grant nothing more.
      assert Gate.allows?(AppAuth, ada, {:report, :view}, %{organization_id: "1"})
      refute Gate.allows?(AppAuth, ada, {:report, :export}, %{organization_id: "1"})
      assert Gate.allows?(AppAuth, ada, {:report, :view}, %{organization_id: nil, title: "Q3"})

      # Taking the role away counts from the next check.
      {_admin_browser, _conn} =
        post(admin_browser, "/admin/set-role", %{user_id: ada.id, role: "user"})

      refute Gate.allows?(AppAuth, ada, {:report, :view})
    end

    test "banned, deleted and missing users may do nothing" do
      {admin_browser, _admin} = signed_in(AppAuth, "root@example.com", role: "admin")
      ada = user(AppAuth, "ada@example.com", role: "support")
      assert Gate.allows?(AppAuth, ada, {:report, :view})

      {admin_browser, conn} = post(admin_browser, "/admin/ban-user", %{user_id: ada.id})
      assert conn.status == 200
      refute Gate.allows?(AppAuth, ada, {:report, :view})

      {_admin_browser, _conn} = post(admin_browser, "/admin/unban-user", %{user_id: ada.id})
      assert Gate.allows?(AppAuth, ada, {:report, :view})

      Repo.delete_all(from(u in "users", where: u.email == "ada@example.com"))
      refute Gate.allows?(AppAuth, ada, {:report, :view})
      refute Gate.allows?(AppAuth, nil, {:report, :view})
      refute Gate.allows?(AppAuth, %{id: nil}, {:report, :view})
      assert Gate.abilities(AppAuth, nil) == %{}
    end

    test "mistakes in a check raise instead of guessing" do
      ada = user(AppAuth, "ada@example.com", role: "support")

      assert_raise ArgumentError, ~r/unknown ability/, fn ->
        Gate.allows?(AppAuth, ada, {:report, :delete})
      end

      assert_raise ArgumentError, ~r/unknown ability/, fn ->
        Gate.allows?(AppAuth, ada, {:invoice, :view})
      end

      assert_raise ArgumentError, ~r/tuples/, fn -> Gate.allows?(AppAuth, ada, :report) end

      # A resource that doesn't say where it belongs.
      assert_raise ArgumentError, ~r/no organization_id or team_id/, fn ->
        Gate.allows?(AppAuth, ada, {:report, :view}, %{id: 1, title: "Q3"})
      end

      assert_raise ArgumentError, ~r/can't tell which organization/, fn ->
        Gate.allows?(AppAuth, ada, {:report, :view}, "report-1")
      end
    end

    test "denials are reported as telemetry, with ids only" do
      ref = make_ref()
      handler = "gate-denied-#{inspect(ref)}"
      test = self()

      :telemetry.attach(
        handler,
        [:authmk, :gate, :denied],
        fn _event, _measurements, metadata, _config -> send(test, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      ada = user(AppAuth, "ada@example.com")
      refute Gate.allows?(AppAuth, ada, {:report, :export}, %{organization_id: 7, secret: "x"})

      assert_receive {^ref, metadata}
      assert metadata.auth == AppAuth
      assert metadata.user_id == ada.id
      assert metadata.ability == {"report", "export"}
      assert metadata.organization_id == "7"
      refute Map.has_key?(metadata, :resource)
    end

    test "organization endpoints say the feature is off" do
      {_browser, _admin} = signed_in(AppAuth, "root@example.com", role: "admin")
      {browser, _admin} = signed_in(AppAuth, "root2@example.com", role: "admin")

      {browser, conn} = get(browser, "/gate/list-roles", %{organization_id: "1"})
      assert json(conn)["error"]["code"] == "feature_disabled"

      {_browser, conn} = post(browser, "/gate/set-team-role", %{team_id: "1", role: "x"})
      assert json(conn)["error"]["code"] == "feature_disabled"

      assert {:error, %{code: :feature_disabled}} = Gate.list_roles(AppAuth, "1")
    end

    test "RequireAbility lets through only users with the ability" do
      ada = user(AppAuth, "ada@example.com", role: "support")
      grace = user(AppAuth, "grace@example.com")

      request = fn conn, opts ->
        conn = FetchSession.call(conn, FetchSession.init(auth: AppAuth))
        RequireAbility.call(conn, RequireAbility.init([auth: AppAuth] ++ opts))
      end

      page = Plug.Test.conn(:get, "/reports")

      assert request.(page, ability: {:report, :view}).status == 401

      ada_page = Testing.sign_in(page, AppAuth, ada)
      refute request.(ada_page, ability: {:report, :view}).halted
      assert request.(ada_page, ability: {:report, :export}).status == 403

      grace_page = Testing.sign_in(page, AppAuth, grace)
      conn = request.(grace_page, ability: {:report, :view}, redirect_to: "/")
      assert {conn.status, Plug.Conn.get_resp_header(conn, "location")} == {302, ["/"]}

      assert_raise ArgumentError, ~r/resource: takes/, fn ->
        RequireAbility.init(auth: AppAuth, ability: {:report, :view}, resource: {:query, "id"})
      end
    end
  end

  describe "with organizations and teams" do
    @describetag auth: OrgAuth

    setup do
      owner = user(OrgAuth, "owner@example.com")

      {:ok, acme} =
        Organization.create_organization(OrgAuth, %{name: "Acme", slug: "acme"}, owner.id)

      {:ok, globex} =
        Organization.create_organization(OrgAuth, %{name: "Globex", slug: "globex"}, owner.id)

      {:ok, finance} = Organization.create_team(OrgAuth, acme.id, %{name: "Finance"})
      {:ok, analysts} = Organization.create_team(OrgAuth, acme.id, %{name: "Analysts"})
      {:ok, globex_team} = Organization.create_team(OrgAuth, globex.id, %{name: "Ops"})

      %{
        owner: owner,
        acme: acme,
        globex: globex,
        finance: finance,
        analysts: analysts,
        globex_team: globex_team
      }
    end

    defp member(org, email, role \\ "member") do
      user = user(OrgAuth, email)
      {:ok, _member} = Organization.add_member(OrgAuth, org.id, user.id, role)
      user
    end

    defp invoice(org, team \\ nil), do: %{organization_id: org.id, team_id: team && team.id}

    test "organization admins may do everything in their own organization only", ctx do
      %{owner: owner, acme: acme, globex: globex} = ctx
      admin = member(acme, "admin@example.com", "admin")

      for user <- [owner, admin], action <- [:view, :update, :delete] do
        assert Gate.allows?(OrgAuth, user, {:invoice, action}, invoice(acme))
      end

      # App-only abilities stay with app roles.
      refute Gate.allows?(OrgAuth, owner, {:billing, :refund}, invoice(acme))

      # Admin in Acme, nothing in Globex: like Microsoft Entra, per organization.
      refute Gate.allows?(OrgAuth, admin, {:invoice, :view}, invoice(globex))
      refute Gate.allows?(OrgAuth, admin, {:invoice, :view})

      {:ok, _member} = Organization.add_member(OrgAuth, globex.id, admin.id, "member")
      refute Gate.allows?(OrgAuth, admin, {:invoice, :view}, invoice(globex))
      assert Gate.allows?(OrgAuth, admin, {:report, :view}, invoice(globex))

      # The organization and team records themselves are resources too.
      assert Gate.allows?(OrgAuth, admin, {:invoice, :delete}, acme)
      assert Gate.allows?(OrgAuth, admin, {:invoice, :delete}, ctx.finance)
      refute Gate.allows?(OrgAuth, admin, {:invoice, :delete}, ctx.globex_team)
      assert Gate.allows?(OrgAuth, admin, {:invoice, :delete}, {:organization, acme.id})
      refute Gate.allows?(OrgAuth, admin, {:invoice, :delete}, {:organization, "nope"})
    end

    test "teams pass their role down, and member roles narrow it", ctx do
      %{acme: acme, finance: finance, analysts: analysts} = ctx
      grace = member(acme, "grace@example.com")

      # A plain member gets what the code gives members.
      assert Gate.allows?(OrgAuth, grace, {:report, :view}, invoice(acme))
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # Joining a team without a role gives nothing more.
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, finance.id, grace.id)
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # The team gets a role; Grace joined as an employee (the default).
      {:ok, finance} = Gate.set_team_role(OrgAuth, finance.id, "finance")
      assert finance.role == "finance"
      assert Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))
      refute Gate.allows?(OrgAuth, grace, {:invoice, :update}, invoice(acme))

      # A manager may update, but not delete: the team may, the role doesn't.
      {:ok, team_member} = Gate.set_team_member_role(OrgAuth, finance.id, grace.id, "manager")
      assert team_member.role == "manager"
      assert Gate.allows?(OrgAuth, grace, {:invoice, :update}, invoice(acme))
      refute Gate.allows?(OrgAuth, grace, {:invoice, :delete}, invoice(acme))

      # A member role never adds what the team doesn't have.
      refute Gate.allows?(OrgAuth, grace, {:report, :export}, invoice(acme))

      # Without a role in the team, a member gets all the team has.
      {:ok, _team_member} = Gate.set_team_member_role(OrgAuth, finance.id, grace.id, nil)
      assert Gate.allows?(OrgAuth, grace, {:invoice, :delete}, invoice(acme))

      # Team access counts in its organization only.
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view})
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(ctx.globex))

      # A record of another team: only that team's grants, plus
      # organization-wide ones.
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme, analysts))
      assert Gate.allows?(OrgAuth, grace, {:report, :view}, invoice(acme, analysts))
      assert Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme, finance))
      assert Gate.allows?(OrgAuth, grace, {:invoice, :view}, %{team_id: finance.id})

      # Several teams add up.
      {:ok, _analysts} = Gate.set_team_role(OrgAuth, analysts.id, "analysts")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, analysts.id, grace.id)

      assert Gate.abilities(OrgAuth, grace, invoice(acme)) == %{
               "invoice" => ["delete", "update", "view"],
               "report" => ["view"]
             }

      # Leaving a team takes its access away.
      {:ok, _team_member} = Organization.remove_team_member(OrgAuth, finance.id, grace.id)
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # So does leaving the organization.
      {:ok, _member} = Organization.remove_member(OrgAuth, acme.id, grace.id)
      refute Gate.allows?(OrgAuth, grace, {:report, :view}, invoice(acme))
    end

    test "a resource's team must be in the organization it names", ctx do
      %{acme: acme, globex: globex, finance: finance} = ctx
      grace = member(acme, "grace@example.com")
      {:ok, _finance} = Gate.set_team_role(OrgAuth, finance.id, "finance")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, finance.id, grace.id)
      {:ok, _member} = Organization.add_member(OrgAuth, globex.id, grace.id, "admin")

      # Acme's team, said to be in Globex where Grace is an admin: nothing.
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(globex, finance))
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, {:team, "not-a-team"})
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, {:team, nil})
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, {:organization, nil})
      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, %{team_id: Ecto.UUID.generate()})

      # Where the resource is decides, not which organization the user is in.
      assert Gate.allows?(OrgAuth, grace, {:invoice, :delete}, invoice(globex))
      refute Gate.allows?(OrgAuth, grace, {:invoice, :delete}, invoice(acme))
    end

    test "app roles count in every organization, app admins everywhere", ctx do
      support = user(OrgAuth, "support@example.com", role: "support")
      root = user(OrgAuth, "root@example.com", role: "admin")

      assert Gate.allows?(OrgAuth, support, {:invoice, :view}, invoice(ctx.acme))

      assert Gate.allows?(
               OrgAuth,
               support,
               {:invoice, :view},
               invoice(ctx.globex, ctx.globex_team)
             )

      refute Gate.allows?(OrgAuth, support, {:invoice, :update}, invoice(ctx.acme))

      assert Gate.allows?(OrgAuth, root, {:billing, :refund}, invoice(ctx.acme))
      assert Gate.allows?(OrgAuth, root, {:invoice, :delete}, invoice(ctx.globex, ctx.finance))
    end

    test "organizations override the code's roles and define their own", ctx do
      %{acme: acme, globex: globex, finance: finance, analysts: analysts} = ctx
      grace = member(acme, "grace@example.com")
      {:ok, _finance} = Gate.set_team_role(OrgAuth, finance.id, "finance")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, finance.id, grace.id)
      assert Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # Acme's employees may only look at reports.
      assert {:ok, %{source: "override", permission: %{"report" => ["view"]}}} =
               Gate.put_role(OrgAuth, acme.id, :team_member, "employee", %{report: [:view]})

      refute Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # Other organizations keep the code's default.
      bob = member(globex, "bob@example.com")
      {:ok, _ops} = Gate.set_team_role(OrgAuth, ctx.globex_team.id, "finance")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, ctx.globex_team.id, bob.id)
      assert Gate.allows?(OrgAuth, bob, {:invoice, :view}, invoice(globex))

      # Back to the default.
      assert {:ok, %{status: true}} =
               Gate.delete_role(OrgAuth, acme.id, "team_member", "employee")

      assert Gate.allows?(OrgAuth, grace, {:invoice, :view}, invoice(acme))

      # Acme's own team role and member role.
      {:ok, auditors} =
        Gate.put_role(OrgAuth, acme.id, :team, "auditors", %{
          "invoice" => ["view"],
          "report" => ["view", "export"]
        })

      assert auditors.source == "organization"
      {:ok, _role} = Gate.put_role(OrgAuth, acme.id, :team_member, "lead", %{report: [:export]})
      {:ok, analysts} = Gate.set_team_role(OrgAuth, analysts.id, "auditors")
      assert analysts.role == "auditors"
      alan = member(acme, "alan@example.com")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, analysts.id, alan.id)
      {:ok, _team_member} = Gate.set_team_member_role(OrgAuth, analysts.id, alan.id, "lead")
      assert Gate.abilities(OrgAuth, alan, invoice(acme)) == %{"report" => ["export", "view"]}

      # Acme's roles don't exist in Globex.
      assert {:error, %{code: :invalid_role}} =
               Gate.set_team_role(OrgAuth, ctx.globex_team.id, "auditors")

      assert {:error, %{code: :invalid_role}} = Gate.set_team_role(OrgAuth, finance.id, "nope")

      assert {:error, %{code: :invalid_role}} =
               Gate.set_team_member_role(OrgAuth, analysts.id, alan.id, "auditors")

      # A role a team has can't go; once nobody has it, it can.
      assert {:error, %{code: :role_assigned}} =
               Gate.delete_role(OrgAuth, acme.id, :team, "auditors")

      assert {:error, %{code: :role_assigned}} =
               Gate.delete_role(OrgAuth, acme.id, :team_member, "lead")

      {:ok, _analysts} = Gate.set_team_role(OrgAuth, analysts.id, nil)
      assert {:ok, _} = Gate.delete_role(OrgAuth, acme.id, :team, "auditors")

      assert {:error, %{code: :role_not_found}} =
               Gate.delete_role(OrgAuth, acme.id, :team, "auditors")

      # Member roles of the organization are overridden the same way.
      {:ok, _role} = Gate.put_role(OrgAuth, acme.id, :organization, "member", %{})
      refute Gate.allows?(OrgAuth, alan, {:report, :view}, invoice(acme))

      assert {:ok, roles} = Gate.list_roles(OrgAuth, acme.id)

      assert %{level: :organization, role: "member", permission: %{}, source: "override"} in roles

      assert %{
               level: :team,
               role: "analysts",
               permission: %{"report" => ["export", "view"]},
               source: "code"
             } in roles

      assert %{
               level: :team_member,
               role: "lead",
               permission: %{"report" => ["export"]},
               source: "organization"
             } in roles
    end

    test "organizations can't grant more than the code allows", ctx do
      %{acme: acme} = ctx

      for permission <- [
            %{billing: [:refund]},
            %{invoice: [:approve]},
            %{payroll: [:view]},
            %{"invoice" => "view"},
            %{"invoice" => [%{}]},
            %{"invoice" => [nil]},
            [invoice: [:view]]
          ] do
        assert {:error, %{code: :invalid_permission}} =
                 Gate.put_role(OrgAuth, acme.id, :team, "custom", permission)
      end

      for name <- ["", "Has Space", "UPPER", "a,b", String.duplicate("a", 65), nil, 42] do
        assert {:error, %{code: :invalid_role_name}} =
                 Gate.put_role(OrgAuth, acme.id, :team, name, %{invoice: [:view]})
      end

      assert {:error, %{code: :invalid_role_level}} =
               Gate.put_role(OrgAuth, acme.id, :app, "staff", %{invoice: [:view]})

      for id <- [Ecto.UUID.generate(), "not-an-id", nil] do
        assert {:error, %{code: :organization_not_found}} = Gate.list_roles(OrgAuth, id)
        assert {:error, %{code: :team_not_found}} = Gate.set_team_role(OrgAuth, id, "finance")
      end

      grace = user(OrgAuth, "grace@example.com")

      assert {:error, %{code: :member_not_found}} =
               Gate.set_team_member_role(OrgAuth, ctx.finance.id, grace.id, "manager")

      # Rows written before the code changed grant only what's still allowed.
      {:ok, _role} = Gate.put_role(OrgAuth, acme.id, :team, "finance", %{invoice: [:view]})

      Repo.update_all(from(r in "access_roles", where: r.role == "finance"),
        set: [permission: ~s({"invoice": ["view", "approve"], "billing": ["refund"]})]
      )

      bob = member(acme, "bob@example.com")
      {:ok, _finance} = Gate.set_team_role(OrgAuth, ctx.finance.id, "finance")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, ctx.finance.id, bob.id)
      {:ok, _team_member} = Gate.set_team_member_role(OrgAuth, ctx.finance.id, bob.id, nil)

      assert Gate.abilities(OrgAuth, bob, invoice(acme)) == %{
               "invoice" => ["view"],
               "report" => ["view"]
             }
    end

    test "organization admins manage their access through the endpoints", ctx do
      %{owner: owner, acme: acme, globex: globex, finance: finance} = ctx
      {owner_browser, _owner} = sign_in_as(owner)
      {grace_browser, grace} = signed_in(OrgAuth, "grace@example.com")
      {:ok, _member} = Organization.add_member(OrgAuth, acme.id, grace.id, "member")
      {:ok, _team_member} = Organization.add_team_member(OrgAuth, finance.id, grace.id)

      # Members can't.
      {grace_browser, conn} =
        post(grace_browser, "/gate/set-team-role", %{team_id: finance.id, role: "finance"})

      assert conn.status == 403

      {grace_browser, conn} =
        post(grace_browser, "/gate/set-role", %{
          organization_id: acme.id,
          level: "team",
          role: "finance",
          permission: %{invoice: ["view"]}
        })

      assert conn.status == 403
      {grace_browser, conn} = get(grace_browser, "/gate/list-roles", %{organization_id: acme.id})
      assert conn.status == 403

      # The owner can.
      {owner_browser, conn} =
        post(owner_browser, "/gate/set-team-role", %{team_id: finance.id, role: "finance"})

      assert json(conn)["role"] == "finance"

      # The Organization plugin's own endpoint can't set it.
      {owner_browser, conn} =
        post(owner_browser, "/organization/update-team", %{
          team_id: finance.id,
          data: %{name: "Money", role: "analysts"}
        })

      assert {json(conn)["name"], json(conn)["role"]} == {"Money", "finance"}

      {owner_browser, conn} =
        post(owner_browser, "/gate/set-team-member-role", %{
          team_id: finance.id,
          user_id: grace.id,
          role: "manager"
        })

      assert json(conn)["role"] == "manager"

      {owner_browser, conn} =
        post(owner_browser, "/gate/set-role", %{
          organization_id: acme.id,
          level: "team_member",
          role: "reviewer",
          permission: %{invoice: ["view"]}
        })

      assert json(conn) == %{
               "level" => "team_member",
               "role" => "reviewer",
               "permission" => %{"invoice" => ["view"]},
               "source" => "organization"
             }

      {owner_browser, conn} =
        post(owner_browser, "/gate/set-role", %{
          organization_id: acme.id,
          level: "team",
          role: "finance",
          permission: %{billing: ["refund"]}
        })

      assert json(conn)["error"]["code"] == "invalid_permission"

      {owner_browser, conn} = get(owner_browser, "/gate/list-roles", %{organization_id: acme.id})
      roles = json(conn)["roles"]

      assert json(conn)["abilities"] == %{
               "invoice" => ["delete", "update", "view"],
               "report" => ["export", "view"]
             }

      assert Gate.organization_abilities(OrgAuth) == json(conn)["abilities"]

      assert %{"level" => "team_member", "role" => "reviewer", "source" => "organization"} =
               List.last(roles)

      {owner_browser, conn} =
        post(owner_browser, "/gate/delete-role", %{
          organization_id: acme.id,
          level: "team_member",
          role: "reviewer"
        })

      assert json(conn) == %{"status" => true}

      # Grace sees what she may do in Acme.
      {_grace_browser, conn} = get(grace_browser, "/gate/abilities", %{organization_id: acme.id})

      assert json(conn)["abilities"] == %{
               "invoice" => ["update", "view"],
               "report" => ["view"]
             }

      # The owner of Acme isn't an admin of an organization they're not in.
      {:ok, initech} =
        Organization.create_organization(OrgAuth, %{name: "Initech", slug: "initech"}, grace.id)

      {_owner_browser, conn} =
        get(owner_browser, "/gate/list-roles", %{organization_id: initech.id})

      assert conn.status == 403

      # App admins may, in any organization.
      {root_browser, _root} = signed_in(OrgAuth, "root@example.com", role: "admin")
      {_root_browser, conn} = get(root_browser, "/gate/list-roles", %{organization_id: globex.id})
      assert conn.status == 200

      # Every change is in the audit log.
      %{events: events} = AuditLog.list_events(OrgAuth, organization_id: acme.id, limit: 100)
      events = Enum.map(events, & &1.event)
      assert "access_role.created" in events
      assert "access_role.deleted" in events
      assert "team.updated" in events
    end

    test "deleting an organization deletes its roles", ctx do
      {:ok, _role} = Gate.put_role(OrgAuth, ctx.acme.id, :team, "auditors", %{invoice: [:view]})
      {:ok, _role} = Gate.put_role(OrgAuth, ctx.globex.id, :team, "auditors", %{invoice: [:view]})
      {:ok, _deleted} = Organization.delete_organization(OrgAuth, ctx.acme.id)

      assert Repo.all(from(r in "access_roles", select: r.organization_id)) == [
               to_string(ctx.globex.id)
             ]
    end

    test "an organization has a limited number of roles", ctx do
      for n <- 1..100 do
        {:ok, _role} = Gate.put_role(OrgAuth, ctx.acme.id, :team, "role-#{n}", %{})
      end

      assert {:error, %{code: :role_limit_reached}} =
               Gate.put_role(OrgAuth, ctx.acme.id, :team, "one-more", %{})

      # Changing one that exists is fine.
      assert {:ok, _role} =
               Gate.put_role(OrgAuth, ctx.acme.id, :team, "role-1", %{invoice: [:view]})
    end

    test "RequireAbility checks the organization in the path", ctx do
      %{acme: acme, globex: globex} = ctx
      grace = member(acme, "grace@example.com")

      request = fn organization_id, opts ->
        conn =
          Plug.Test.conn(:get, "/orgs/#{organization_id}/reports")
          |> Testing.sign_in(OrgAuth, grace)
          |> Map.put(:path_params, %{"organization_id" => to_string(organization_id)})
          |> FetchSession.call(FetchSession.init(auth: OrgAuth))

        RequireAbility.call(conn, RequireAbility.init([auth: OrgAuth] ++ opts))
      end

      opts = [ability: {:report, :view}, resource: {:param, :organization, "organization_id"}]
      refute request.(acme.id, opts).halted
      assert request.(globex.id, opts).status == 403
      assert request.("not-an-id", opts).status == 403

      # Without a resource, only app roles count.
      assert request.(acme.id, ability: {:report, :view}).status == 403
    end

    test "RequireAbility can check the session's active organization", ctx do
      {browser, grace} = signed_in(OrgAuth, "grace@example.com")
      {:ok, _member} = Organization.add_member(OrgAuth, ctx.acme.id, grace.id, "member")

      request = fn browser ->
        conn =
          Enum.reduce(browser.cookies, Plug.Test.conn(:get, "/reports"), fn {name, value}, conn ->
            Plug.Test.put_req_cookie(conn, name, value)
          end)
          |> FetchSession.call(FetchSession.init(auth: OrgAuth))

        opts = [auth: OrgAuth, ability: {:report, :view}, resource: :active_organization]
        RequireAbility.call(conn, RequireAbility.init(opts))
      end

      # No active organization yet: nothing in an organization counts.
      assert request.(browser).status == 403

      {browser, conn} = post(browser, "/organization/set-active", %{organization_id: ctx.acme.id})
      assert conn.status == 200
      refute request.(browser).halted
    end
  end

  describe "configuration" do
    @describetag auth: AppAuth

    test "the Admin plugin is required" do
      defmodule NoAdminAuth do
        use Authmk,
          otp_app: :authmk,
          repo: Authmk.Test.Repo,
          base_url: "http://localhost:4000",
          plugins: [
            Authmk.Plugins.EmailPassword,
            {Authmk.Plugins.Gate, abilities: [report: [:view]]}
          ]
      end

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(NoAdminAuth)

      assert message =~ "needs Authmk.Plugins.Admin"
    end

    test "rules that don't fit the plugins or abilities fail at startup" do
      cases = [
        {[abilities: [report: [:view]], team_roles: [a: [report: [:view]]]],
         [Authmk.Plugins.Organization], "need Authmk.Plugins.Organization with teams"},
        {[abilities: [report: [:view]], organization_roles: [member: [report: [:view]]]], [],
         "organization_roles need Authmk.Plugins.Organization"},
        {[abilities: [report: [:view]], app_roles: [auditor: [report: [:view]]]], [],
         "app role auditor is not a role of Authmk.Plugins.Admin's access_control"},
        {[abilities: [report: [:view]], app_roles: [a: [report: [:edit]]]], [],
         "unknown report actions: edit"},
        {[abilities: [report: [:view]], app_roles: [a: [invoice: [:view]]]], [],
         "unknown resource invoice"},
        {[
           abilities: [report: [:view], billing: [:refund]],
           app_only: [billing: [:refund]],
           organization_roles: [member: [billing: [:refund]]]
         ], [Authmk.Plugins.Organization], "grants an app-only ability"},
        {[
           abilities: [report: [:view]],
           team_member_roles: [employee: [report: [:view]]],
           default_team_member_role: "manager"
         ], [{Authmk.Plugins.Organization, teams: [enabled: true]}],
         "default_team_member_role \"manager\" is not one of team_member_roles"}
      ]

      for {{gate_opts, plugins, message}, n} <- Enum.with_index(cases) do
        auth = Module.concat(__MODULE__, "BadAuth#{n}")

        Module.create(
          auth,
          quote do
            use Authmk,
              otp_app: :authmk,
              repo: Authmk.Test.Repo,
              base_url: "http://localhost:4000",
              plugins:
                [Authmk.Plugins.EmailPassword, Authmk.Plugins.Admin] ++
                  unquote(Macro.escape(plugins)) ++
                  [{Authmk.Plugins.Gate, unquote(Macro.escape(gate_opts))}]
          end,
          Macro.Env.location(__ENV__)
        )

        assert {:error, {{%ArgumentError{message: raised}, _stack}, _child}} =
                 start_supervised(auth)

        assert raised =~ message
      end
    end
  end

  defp sign_in_as(user) do
    {:ok, _account} =
      Credentials.set_password(Context.new(OrgAuth.config()), user, @password)

    {browser, conn} =
      post(Browser.new(OrgAuth), "/sign-in/email", %{
        email: user.email,
        password: @password
      })

    200 = conn.status
    {browser, user}
  end
end
