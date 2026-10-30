defmodule Authmk.OrganizationTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization, send_invitation_email: &__MODULE__.send_invitation/2}
      ]

    def send_invitation(%{id: id, email: email, role: role, organization: org}, _ctx),
      do: send(self(), {:invitation, email, id, role, org.name})
  end

  @moduletag auth: Auth

  defp user(email) do
    {browser, _user} =
      sign_up(Browser.new(Auth), %{email: email, name: email |> String.split("@") |> hd()})

    browser
  end

  defp create_org(browser, name \\ "Acme", slug \\ "acme") do
    {browser, conn} = post(browser, "/organization/create", %{name: name, slug: slug})
    {browser, json(conn)}
  end

  # Invites `email` with `role` and has them accept; returns their browser.
  defp invite_and_join(owner, org, email, role) do
    {_owner, conn} =
      post(owner, "/organization/invite-member", %{
        organization_id: org["id"],
        email: email,
        role: role
      })

    assert conn.status == 200, inspect(json(conn))
    assert_received {:invitation, ^email, id, ^role, _name}
    {browser, conn} = post(user(email), "/organization/accept-invitation", %{invitation_id: id})
    assert conn.status == 200, inspect(json(conn))
    browser
  end

  defp member_id(owner, org, email) do
    {_owner, conn} = get(owner, "/organization/list-members", %{organization_id: org["id"]})
    Enum.find(json(conn)["members"], &(&1["user"]["email"] == email))["id"]
  end

  defp session(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["session"]
  end

  describe "organizations" do
    test "the creator owns it, and it becomes active", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)

      assert org["name"] == "Acme"
      assert [%{"role" => "owner"}] = org["members"]
      assert session(owner)["active_organization_id"] == org["id"]

      {owner, conn} = get(owner, "/organization/list")
      assert [%{"slug" => "acme"}] = json(conn)

      {_owner, conn} = post(owner, "/organization/check-slug", %{slug: "acme"})
      assert json(conn)["error"]["code"] == "slug_taken"
    end

    test "slugs are unique", %{browser: _browser} do
      {_ada, _org} = create_org(user("ada@example.com"))
      {_grace, org} = create_org(user("grace@example.com"))
      assert org["error"]["code"] == "slug_taken"
    end

    test "owners update and delete; members can't", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      member = invite_and_join(owner, org, "grace@example.com", "member")

      {member, conn} =
        post(member, "/organization/update", %{organization_id: org["id"], data: %{name: "Mine"}})

      assert conn.status == 403
      {_member, conn} = post(member, "/organization/delete", %{organization_id: org["id"]})
      assert conn.status == 403

      # The active organization is the default.
      {owner, conn} =
        post(owner, "/organization/update", %{data: %{name: "Acme Inc", slug: "acme-inc"}})

      assert json(conn)["name"] == "Acme Inc"

      {owner, conn} = post(owner, "/organization/delete", %{organization_id: org["id"]})
      assert json(conn) == %{"status" => true}
      assert session(owner)["active_organization_id"] == nil
      assert Repo.aggregate("members", :count) == 0
    end

    test "admins update but don't delete", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      admin = invite_and_join(owner, org, "grace@example.com", "admin")

      {admin, conn} =
        post(admin, "/organization/update", %{organization_id: org["id"], data: %{name: "Acme 2"}})

      assert json(conn)["name"] == "Acme 2"
      {_admin, conn} = post(admin, "/organization/delete", %{organization_id: org["id"]})
      assert conn.status == 403
    end

    test "the full organization: members and pending invitations", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      _member = invite_and_join(owner, org, "grace@example.com", "member")

      {owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "alan@example.com", role: "admin"})

      {_owner, conn} =
        get(owner, "/organization/get-full-organization", %{organization_slug: "acme"})

      body = json(conn)

      assert Enum.map(body["members"], & &1["user"]["email"]) == [
               "ada@example.com",
               "grace@example.com"
             ]

      assert [%{"email" => "alan@example.com", "status" => "pending"}] = body["invitations"]
    end

    test "the active organization: set, cleared, and only for members", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      {owner, _other} = create_org(owner, "Other", "other")

      {owner, conn} = post(owner, "/organization/set-active", %{organization_id: org["id"]})
      assert json(conn)["slug"] == "acme"
      assert session(owner)["active_organization_id"] == org["id"]

      {owner, _conn} = post(owner, "/organization/set-active", %{organization_id: nil})
      assert session(owner)["active_organization_id"] == nil

      {_stranger, conn} =
        post(user("eve@example.com"), "/organization/set-active", %{organization_id: org["id"]})

      assert json(conn)["error"]["code"] == "not_a_member"

      {_owner, conn} = post(owner, "/organization/update", %{data: %{name: "x"}})
      assert json(conn)["error"]["code"] == "no_active_organization"
    end

    test "strangers see nothing", %{browser: _browser} do
      {_owner, org} = create_org(user("ada@example.com"))
      stranger = user("eve@example.com")

      for {method, path, params} <- [
            {:get, "/organization/get-full-organization", %{organization_id: org["id"]}},
            {:get, "/organization/list-members", %{organization_id: org["id"]}},
            {:get, "/organization/list-invitations", %{organization_id: org["id"]}},
            {:post, "/organization/invite-member",
             %{organization_id: org["id"], email: "eve2@example.com", role: "owner"}}
          ] do
        {_stranger, conn} = request(stranger, method, path, params)
        assert json(conn)["error"]["code"] == "not_a_member", path
      end
    end
  end

  describe "members and roles" do
    test "only owners hand out or take the owner role", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      admin = invite_and_join(owner, org, "grace@example.com", "admin")
      _member = invite_and_join(owner, org, "alan@example.com", "member")
      alan = member_id(owner, org, "alan@example.com")
      ada = member_id(owner, org, "ada@example.com")

      {admin, conn} =
        post(admin, "/organization/update-member-role", %{member_id: alan, role: "owner"})

      assert json(conn)["error"]["code"] == "owner_required"
      {admin, conn} = post(admin, "/organization/remove-member", %{member_id_or_email: ada})
      assert json(conn)["error"]["code"] == "owner_required"

      {admin, conn} =
        post(admin, "/organization/invite-member", %{email: "x@example.com", role: "owner"})

      assert json(conn)["error"]["code"] == "owner_required"

      {_admin, conn} =
        post(admin, "/organization/update-member-role", %{member_id: alan, role: "admin"})

      assert json(conn)["member"]["role"] == "admin"

      {_owner, conn} =
        post(owner, "/organization/update-member-role", %{member_id: alan, role: "owner"})

      assert json(conn)["member"]["role"] == "owner"
    end

    test "an organization keeps an owner", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      ada = member_id(owner, org, "ada@example.com")

      {owner, conn} = post(owner, "/organization/leave", %{organization_id: org["id"]})
      assert json(conn)["error"]["code"] == "cannot_remove_last_owner"

      {owner, conn} =
        post(owner, "/organization/update-member-role", %{member_id: ada, role: "admin"})

      assert json(conn)["error"]["code"] == "cannot_remove_last_owner"

      # With a second owner, the first may go.
      _second = invite_and_join(owner, org, "grace@example.com", "owner")
      {_owner, conn} = post(owner, "/organization/leave", %{organization_id: org["id"]})
      assert json(conn)["member"]["role"] == "owner"
    end

    test "members are removed by id or email, and members leave", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      _grace = invite_and_join(owner, org, "grace@example.com", "member")
      alan = invite_and_join(owner, org, "alan@example.com", "member")

      {owner, conn} =
        post(owner, "/organization/remove-member", %{member_id_or_email: "Grace@Example.com"})

      assert json(conn)["member"]

      {owner, _conn} =
        post(alan, "/organization/leave", %{organization_id: org["id"]})
        |> then(fn {_alan, conn} -> {owner, conn} end)

      {_owner, conn} = get(owner, "/organization/list-members")
      assert json(conn)["total"] == 1
    end

    test "invalid roles are refused", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, _org} = create_org(owner)

      {_owner, conn} =
        post(owner, "/organization/invite-member", %{email: "g@example.com", role: "emperor"})

      assert json(conn)["error"]["code"] == "invalid_role"
    end

    test "the active member, their role, and permission checks", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      member = invite_and_join(owner, org, "grace@example.com", "member")

      {member, conn} = get(member, "/organization/get-active-member")
      assert json(conn)["user"]["email"] == "grace@example.com"
      {member, conn} = get(member, "/organization/get-active-member-role")
      assert json(conn) == %{"role" => "member"}

      {member, conn} =
        post(member, "/organization/has-permission", %{permissions: %{ac: ["read"]}})

      assert json(conn) == %{"success" => true}

      {_member, conn} =
        post(member, "/organization/has-permission", %{permissions: %{member: ["delete"]}})

      assert json(conn) == %{"success" => false}
    end
  end

  describe "invitations" do
    test "accepted by the invitee, who becomes a member of an active organization", %{
      browser: _browser
    } do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)

      {_owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "Grace@Example.com", role: "admin"})

      assert_received {:invitation, "grace@example.com", id, "admin", "Acme"}

      grace = user("grace@example.com")
      {grace, conn} = get(grace, "/organization/list-user-invitations")
      assert [%{"id" => ^id}] = json(conn)
      {grace, conn} = get(grace, "/organization/get-invitation", %{id: id})
      assert json(conn)["organization_name"] == "Acme"

      {grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})
      assert json(conn)["member"]["role"] == "admin"
      assert json(conn)["invitation"]["status"] == "accepted"
      assert session(grace)["active_organization_id"] == org["id"]

      {_grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})
      assert json(conn)["error"]["code"] == "invitation_not_found"
    end

    test "only the invitee sees, accepts or rejects it", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, _org} = create_org(owner)

      {_owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert_received {:invitation, _email, id, _role, _name}

      eve = user("eve@example.com")

      for {method, path, params} <- [
            {:get, "/organization/get-invitation", %{id: id}},
            {:post, "/organization/accept-invitation", %{invitation_id: id}},
            {:post, "/organization/reject-invitation", %{invitation_id: id}}
          ] do
        {_eve, conn} = request(eve, method, path, params)
        assert json(conn)["error"]["code"] == "invitation_not_found", path
      end

      {_grace, conn} =
        post(user("grace@example.com"), "/organization/reject-invitation", %{invitation_id: id})

      assert json(conn)["invitation"]["status"] == "rejected"
    end

    test "canceled and expired invitations can't be accepted", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, _org} = create_org(owner)
      grace = user("grace@example.com")

      {owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert_received {:invitation, _email, canceled, _role, _name}
      {owner, conn} = post(owner, "/organization/cancel-invitation", %{invitation_id: canceled})
      assert json(conn)["status"] == "canceled"
      {grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: canceled})
      assert json(conn)["error"]["code"] == "invitation_not_found"

      {_owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert_received {:invitation, _email, expired, _role, _name}

      Repo.update_all(from(i in "invitations"),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
      )

      {_grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: expired})
      assert json(conn)["error"]["code"] == "invitation_expired"
    end

    test "one pending invitation per email; resending refreshes it", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, _org} = create_org(owner)

      {owner, _conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert_received {:invitation, _email, first, _role, _name}

      {owner, conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert json(conn)["error"]["code"] == "already_invited"

      {_owner, conn} =
        post(owner, "/organization/invite-member", %{
          email: "grace@example.com",
          role: "admin",
          resend: true
        })

      assert json(conn)["id"] == first
      assert json(conn)["role"] == "admin"
      assert_received {:invitation, _email, ^first, "admin", _name}
    end

    test "members can't be invited again", %{browser: _browser} do
      owner = user("ada@example.com")
      {owner, org} = create_org(owner)
      _grace = invite_and_join(owner, org, "grace@example.com", "member")

      {_owner, conn} =
        post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

      assert json(conn)["error"]["code"] == "already_member"
    end
  end
end

defmodule Authmk.OrganizationOptionsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Organization
  alias Authmk.Test.{Browser, Repo}

  defmodule Hooks do
    @behaviour Authmk.Plugins.Organization.Hooks

    @impl true
    def before_event(:create_organization, %{"name" => "Forbidden"}, _ctx),
      do: {:error, Authmk.Error.custom(:name_not_allowed, 422, "Pick another name")}

    def before_event(:create_organization, attrs, _ctx),
      do: {:ok, Map.put(attrs, "logo", "/default.png")}

    def before_event(_event, data, _ctx), do: {:ok, data}

    @impl true
    def after_event(event, _record, _ctx), do: send(self(), {:organization_event, event})
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      schema: [organization: [additional_fields: [plan: [type: :string, default: "free"]]]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization,
         send_invitation_email: &__MODULE__.send_invitation/2,
         organization_limit: 1,
         membership_limit: 2,
         cancel_pending_invitations_on_re_invite: true,
         require_email_verification_on_invitation: true,
         hooks: Authmk.OrganizationOptionsTest.Hooks}
      ]

    def send_invitation(%{id: id, email: email}, _ctx), do: send(self(), {:invitation, email, id})
  end

  @moduletag auth: Auth

  defp user(email), do: email |> then(&sign_up(Browser.new(Auth), %{email: &1})) |> elem(0)

  test "hooks change and stop events, and hear about them", %{browser: _browser} do
    owner = user("ada@example.com")
    {owner, conn} = post(owner, "/organization/create", %{name: "Forbidden", slug: "f"})
    assert json(conn)["error"]["code"] == "name_not_allowed"

    {_owner, conn} =
      post(owner, "/organization/create", %{name: "Acme", slug: "acme", plan: "pro"})

    assert json(conn)["logo"] == "/default.png"
    # An extra field from the schema config.
    assert json(conn)["plan"] == "pro"
    assert_received {:organization_event, :add_member}
    assert_received {:organization_event, :create_organization}
  end

  test "limits on organizations per user and members per organization", %{browser: _browser} do
    owner = user("ada@example.com")
    {owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    org = json(conn)
    {owner, conn} = post(owner, "/organization/create", %{name: "Two", slug: "two"})
    assert json(conn)["error"]["code"] == "organization_limit_reached"

    {:ok, _member} =
      Organization.add_member(
        Auth,
        org["id"],
        user_id("grace@example.com"),
        "member"
      )

    assert {:error, %{code: :membership_limit_reached}} =
             Organization.add_member(
               Auth,
               org["id"],
               user_id("alan@example.com"),
               "member"
             )

    {_owner, conn} = get(owner, "/organization/list-members")
    assert json(conn)["total"] == 2
  end

  test "re-inviting replaces the pending invitation; invitees must verify their email", %{
    browser: _browser
  } do
    owner = user("ada@example.com")
    {owner, _conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})

    {owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

    assert_received {:invitation, _email, first}

    {_owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "admin"})

    assert_received {:invitation, _email, second}
    assert first != second

    grace = user("grace@example.com")
    {grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: first})
    assert json(conn)["error"]["code"] == "invitation_not_found"
    {_grace, conn} = post(grace, "/organization/accept-invitation", %{invitation_id: second})
    assert json(conn)["error"]["code"] == "email_not_verified"
    assert Repo.aggregate("members", :count) == 1
  end

  defp user_id(email) do
    {_browser, user} = sign_up(Browser.new(Auth), %{email: email})
    user["id"]
  end
end

defmodule Authmk.OrganizationTeamsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization,
         send_invitation_email: &__MODULE__.send_invitation/2,
         teams: [enabled: true, maximum_teams: 2, allow_removing_all_teams: false]}
      ]

    def send_invitation(%{id: id, email: email}, _ctx), do: send(self(), {:invitation, email, id})
  end

  @moduletag auth: Auth

  defp user(email) do
    {browser, user} = sign_up(Browser.new(Auth), %{email: email})
    {browser, user}
  end

  test "teams, their members, the active team and invitations into a team", %{browser: _browser} do
    {owner, _ada} = user("ada@example.com")
    {owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    org = json(conn)

    {owner, conn} = post(owner, "/organization/create-team", %{name: "Design"})
    design = json(conn)
    {owner, _conn} = post(owner, "/organization/create-team", %{name: "Ops"})
    {owner, conn} = post(owner, "/organization/create-team", %{name: "Three"})
    assert json(conn)["error"]["code"] == "team_limit_reached"

    # Invited straight into a team.
    {owner, _conn} =
      post(owner, "/organization/invite-member", %{
        email: "grace@example.com",
        role: "member",
        team_id: design["id"]
      })

    assert_received {:invitation, _email, id}
    {grace, grace_user} = user("grace@example.com")
    {grace, _conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})

    {grace, conn} = get(grace, "/organization/list-user-teams")
    assert [%{"name" => "Design"}] = json(conn)
    {grace, conn} = post(grace, "/organization/set-active-team", %{team_id: design["id"]})
    assert json(conn)["name"] == "Design"
    {grace, conn} = get(grace, "/organization/list-team-members")
    assert [%{"user_id" => grace_id}] = json(conn)
    assert grace_id == grace_user["id"]

    # Only organization members join teams.
    {_eve, eve} = user("eve@example.com")

    {owner, conn} =
      post(owner, "/organization/add-team-member", %{team_id: design["id"], user_id: eve["id"]})

    assert json(conn)["error"]["code"] == "member_not_found"

    {owner, conn} =
      post(owner, "/organization/update-team", %{team_id: design["id"], data: %{name: "UX"}})

    assert json(conn)["name"] == "UX"

    # Leaving the organization leaves its teams.
    {_grace, _conn} = post(grace, "/organization/leave", %{organization_id: org["id"]})
    assert Repo.aggregate("team_members", :count) == 0

    {owner, conn} = post(owner, "/organization/remove-team", %{team_id: design["id"]})
    assert json(conn) == %{"status" => true}
    {owner, conn} = get(owner, "/organization/list-teams")
    [last] = json(conn)
    {_owner, conn} = post(owner, "/organization/remove-team", %{team_id: last["id"]})
    assert json(conn)["error"]["code"] == "cannot_remove_last_team"
  end
end

defmodule Authmk.OrganizationRolesTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization,
         send_invitation_email: &__MODULE__.send_invitation/2,
         dynamic_access_control: [enabled: true, maximum_roles_per_organization: 2]}
      ]

    def send_invitation(%{id: id, email: email}, _ctx), do: send(self(), {:invitation, email, id})
  end

  @moduletag auth: Auth

  defp user(email), do: Browser.new(Auth) |> sign_up(%{email: email}) |> elem(0)

  test "an organization's own roles grant what they say", %{browser: _browser} do
    owner = user("ada@example.com")
    {owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    org = json(conn)

    {owner, conn} =
      post(owner, "/organization/create-role", %{
        role: "recruiter",
        permission: %{invitation: ["create"]}
      })

    assert json(conn)["permission"] == %{"invitation" => ["create"]}

    {owner, conn} = post(owner, "/organization/create-role", %{role: "owner", permission: %{}})
    assert json(conn)["error"]["code"] == "role_exists"

    {owner, conn} =
      post(owner, "/organization/create-role", %{
        role: "hacker",
        permission: %{servers: ["reboot"]}
      })

    assert json(conn)["error"]["code"] == "invalid_role"

    {owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "recruiter"})

    assert_received {:invitation, _email, id}
    grace = user("grace@example.com")
    {grace, _conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})

    # The recruiter invites, but can't make roles beyond what they have.
    {grace, conn} =
      post(grace, "/organization/invite-member", %{email: "alan@example.com", role: "member"})

    assert json(conn)["status"] == "pending"

    # Nor invite someone stronger than themselves.
    {grace, conn} =
      post(grace, "/organization/invite-member", %{email: "eve@example.com", role: "admin"})

    assert json(conn)["error"]["code"] == "forbidden"

    {_grace, conn} =
      post(grace, "/organization/create-role", %{
        role: "boss",
        permission: %{organization: ["delete"]}
      })

    assert conn.status == 403

    {owner, conn} = post(owner, "/organization/delete-role", %{role: "recruiter"})
    assert json(conn)["error"]["code"] == "role_in_use"

    {owner, conn} = get(owner, "/organization/list-roles", %{organization_id: org["id"]})
    assert [%{"role" => "recruiter"}] = json(conn)

    {owner, conn} =
      post(owner, "/organization/update-role", %{
        role: "recruiter",
        permission: %{invitation: ["create", "cancel"]}
      })

    assert json(conn)["permission"]["invitation"] == ["create", "cancel"]
    {owner, _conn} = post(owner, "/organization/create-role", %{role: "two", permission: %{}})
    {_owner, conn} = post(owner, "/organization/create-role", %{role: "three", permission: %{}})
    assert json(conn)["error"]["code"] == "role_limit_reached"
  end
end

defmodule Authmk.OrganizationCustomPermissionsTest do
  # An app's own resources next to the organization statements.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Organization.Permissions, as: OrgPermissions
  alias Authmk.Test.Browser

  defmodule Permissions do
    use Authmk.AccessControl,
      statements: OrgPermissions.statements() ++ [project: [:create, :delete]],
      roles: [
        owner: OrgPermissions.statements() ++ [project: [:create, :delete]],
        developer: [project: [:create]]
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
        {Authmk.Plugins.Organization,
         access_control: Permissions, send_invitation_email: &__MODULE__.send_invitation/2}
      ]

    def send_invitation(%{id: id}, _ctx), do: send(self(), {:invitation, id})
  end

  @moduletag auth: Auth

  test "custom roles and permissions are checked on the server", %{browser: _browser} do
    {owner, _user} = sign_up(Browser.new(Auth))
    {owner, _conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})

    {owner, conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

    assert json(conn)["error"]["code"] == "invalid_role"

    {_owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "developer"})

    assert_received {:invitation, id}
    {grace, _user} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    {grace, _conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})

    {grace, conn} =
      post(grace, "/organization/has-permission", %{permissions: %{project: ["create"]}})

    assert json(conn) == %{"success" => true}

    {_grace, conn} =
      post(grace, "/organization/has-permission", %{permissions: %{project: ["delete"]}})

    assert json(conn) == %{"success" => false}
  end
end
