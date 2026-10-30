defmodule Authmk.OrganizationServerTest do
  # An app admin (an admin dashboard, a back office) manages organizations
  # from server code, without being a member of them.
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.Organization
  alias Authmk.Test.{Browser, Repo}

  defmodule Hooks do
    @behaviour Authmk.Plugins.Organization.Hooks

    @impl true
    def before_event(:create_organization, %{"name" => "Forbidden"}, _ctx),
      do: {:error, Authmk.Error.custom(:name_not_allowed, 422, "Pick another name")}

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
      schema: [
        organization: [
          additional_fields: [
            plan: [type: :string, default: "free"],
            internal_note: [type: :string, input: false]
          ]
        ]
      ],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization,
         send_invitation_email: &__MODULE__.send_invitation/2,
         hooks: Authmk.OrganizationServerTest.Hooks,
         invitation_limit: 3,
         teams: [
           enabled: true,
           maximum_teams: 2,
           maximum_members_per_team: 1,
           allow_removing_all_teams: false
         ]}
      ]

    def send_invitation(%{id: id, email: email, role: role, inviter: inviter}, ctx),
      do: send(self(), {:invitation, email, id, role, inviter.email, ctx.base_url})
  end

  @moduletag auth: Auth

  defp user(email) do
    {browser, user} = sign_up(Browser.new(Auth), %{email: email})
    {browser, user["id"]}
  end

  defp user_id(email), do: email |> user() |> elem(1)

  # Rows, found by slug and name, so the queries work on every database.
  defp members(org) do
    Repo.all(
      from(m in "members",
        join: o in "organizations",
        on: o.id == m.organization_id,
        join: u in "users",
        on: u.id == m.user_id,
        where: o.slug == ^org.slug,
        order_by: u.email,
        select: {u.email, m.role}
      )
    )
  end

  defp team_members(team) do
    Repo.all(
      from(tm in "team_members",
        join: t in "teams",
        on: t.id == tm.team_id,
        join: u in "users",
        on: u.id == tm.user_id,
        where: t.name == ^team.name,
        select: u.email
      )
    )
  end

  describe "organizations" do
    test "created, changed and deleted by an admin who isn't a member", %{browser: _browser} do
      {ada_browser, ada} = user("ada@example.com")

      {:ok, org} =
        Organization.create_organization(
          Auth,
          %{name: "Acme", slug: "acme", plan: "pro", internal_note: "smuggled"},
          ada
        )

      assert {org.name, org.slug, org.plan, org.internal_note} == {"Acme", "acme", "pro", nil}
      assert members(org) == [{"ada@example.com", "owner"}]
      assert_received {:organization_event, :add_member}
      assert_received {:organization_event, :create_organization}

      # The owner sees it and manages it like one they created.
      {ada_browser, conn} = get(ada_browser, "/organization/list")
      assert [%{"slug" => "acme"}] = json(conn)

      {_ada_browser, conn} =
        post(ada_browser, "/organization/update", %{
          organization_id: org.id,
          data: %{name: "Acme Ltd"}
        })

      assert json(conn)["name"] == "Acme Ltd"

      # Slugs stay unique, and hooks still decide.
      assert {:error, %{code: :slug_taken}} =
               Organization.create_organization(Auth, %{name: "Two", slug: "acme"}, ada)

      assert {:error, %{code: :validation_failed}} =
               Organization.create_organization(Auth, %{"name" => "No slug"}, ada)

      assert {:error, %{code: :name_not_allowed}} =
               Organization.create_organization(Auth, %{name: "Forbidden", slug: "f"}, ada)

      {:ok, globex} =
        Organization.create_organization(Auth, %{"name" => "Globex", "slug" => "globex"}, ada)

      assert {:error, %{code: :slug_taken}} =
               Organization.update_organization(Auth, org.id, %{slug: "globex"})

      {:ok, org} =
        Organization.update_organization(Auth, org.id, %{
          "name" => "Acme Inc",
          "slug" => "acme",
          "internal_note" => "smuggled"
        })

      assert {org.name, org.slug, org.internal_note} == {"Acme Inc", "acme", nil}
      assert_received {:organization_event, :update_organization}

      # Deleting takes members, invitations and teams with it.
      {:ok, _member} =
        Organization.add_member(Auth, org.id, user_id("grace@example.com"), "member")

      {:ok, _invitation} =
        Organization.invite_member(Auth, org.id, "alan@example.com", "member", ada)

      {:ok, _team} = Organization.create_team(Auth, org.id, %{name: "Design"})

      {:ok, deleted} = Organization.delete_organization(Auth, org.id)
      assert deleted.id == org.id
      assert_received {:organization_event, :delete_organization}
      assert members(globex) == [{"ada@example.com", "owner"}]
      assert Enum.map(~w(members invitations teams), &Repo.aggregate(&1, :count)) == [1, 0, 0]

      assert {:error, %{code: :organization_not_found}} =
               Organization.update_organization(Auth, org.id, %{name: "Gone"})
    end

    test "unknown and invalid ids are not found", %{browser: _browser} do
      ada = user_id("ada@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada)

      for owner <- [Ecto.UUID.generate(), "not-an-id", nil] do
        assert {:error, %{code: :user_not_found}} =
                 Organization.create_organization(Auth, %{name: "X", slug: "x"}, owner)
      end

      for id <- [Ecto.UUID.generate(), "not-an-id", nil] do
        assert {:error, %{code: :organization_not_found}} =
                 Organization.update_organization(Auth, id, %{name: "X"})

        assert {:error, %{code: :organization_not_found}} =
                 Organization.delete_organization(Auth, id)

        assert {:error, %{code: :organization_not_found}} =
                 Organization.create_team(Auth, id, %{name: "X"})

        assert {:error, %{code: :organization_not_found}} =
                 Organization.invite_member(Auth, id, "grace@example.com", "member", ada)

        assert {:error, %{code: :user_not_found}} =
                 Organization.add_member(Auth, org.id, id, "member")

        assert {:error, %{code: :user_not_found}} =
                 Organization.remove_member(Auth, org.id, id)

        assert {:error, %{code: :user_not_found}} =
                 Organization.invite_member(Auth, org.id, "grace@example.com", "member", id)

        assert {:error, %{code: :team_not_found}} = Organization.update_team(Auth, id, %{})
        assert {:error, %{code: :team_not_found}} = Organization.remove_team(Auth, id)
        assert {:error, %{code: :team_not_found}} = Organization.add_team_member(Auth, id, ada)

        assert {:error, %{code: :invitation_not_found}} =
                 Organization.cancel_invitation(Auth, id)
      end

      {:ok, team} = Organization.create_team(Auth, org.id, %{name: "Design"})

      for id <- [Ecto.UUID.generate(), "not-an-id", nil] do
        assert {:error, %{code: :member_not_found}} =
                 Organization.add_team_member(Auth, team.id, id)

        assert {:error, %{code: :member_not_found}} =
                 Organization.remove_team_member(Auth, team.id, id)
      end

      assert members(org) == [{"ada@example.com", "owner"}]
    end
  end

  describe "members" do
    test "an organization always keeps an owner", %{browser: _browser} do
      ada = user_id("ada@example.com")
      grace = user_id("grace@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada)

      assert {:error, %{code: :cannot_remove_last_owner}} =
               Organization.remove_member(Auth, org.id, ada)

      assert {:error, %{code: :cannot_remove_last_owner}} =
               Organization.set_member_role(Auth, org.id, ada, "admin")

      {:ok, _member} = Organization.add_member(Auth, org.id, grace, "owner")
      {:ok, _member} = Organization.set_member_role(Auth, org.id, ada, "member")

      assert {:error, %{code: :cannot_remove_last_owner}} =
               Organization.remove_member(Auth, org.id, grace)

      assert {:error, %{code: :cannot_remove_last_owner}} =
               Organization.set_member_role(Auth, org.id, grace, "member")

      {:ok, _member} = Organization.remove_member(Auth, org.id, ada)
      assert members(org) == [{"grace@example.com", "owner"}]
    end
  end

  describe "teams" do
    test "created, changed, joined, left and removed", %{browser: _browser} do
      ada = user_id("ada@example.com")
      grace = user_id("grace@example.com")
      eve = user_id("eve@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada)
      {:ok, other} = Organization.create_organization(Auth, %{name: "Other", slug: "other"}, eve)
      {:ok, _member} = Organization.add_member(Auth, org.id, grace, "member")

      {:ok, design} = Organization.create_team(Auth, org.id, %{name: "Design"})
      assert design.organization_id == org.id
      assert_received {:organization_event, :create_team}
      {:ok, ops} = Organization.create_team(Auth, org.id, %{"name" => "Ops"})

      assert {:error, %{code: :team_limit_reached}} =
               Organization.create_team(Auth, org.id, %{name: "Three"})

      assert {:error, %{code: :validation_failed}} = Organization.create_team(Auth, other.id, %{})

      # A team stays in its organization.
      {:ok, design} =
        Organization.update_team(Auth, design.id, %{name: "UX", organization_id: other.id})

      assert {design.name, design.organization_id} == {"UX", org.id}
      assert_received {:organization_event, :update_team}

      # Only the organization's members join its teams, up to the limit.
      assert {:error, %{code: :member_not_found}} =
               Organization.add_team_member(Auth, design.id, eve)

      {:ok, team_member} = Organization.add_team_member(Auth, design.id, grace)
      assert team_member.team_id == design.id
      assert_received {:organization_event, :add_team_member}

      assert {:error, %{code: :team_member_limit_reached}} =
               Organization.add_team_member(Auth, design.id, ada)

      assert team_members(design) == ["grace@example.com"]

      assert {:error, %{code: :member_not_found}} =
               Organization.remove_team_member(Auth, design.id, ada)

      {:ok, _team_member} = Organization.remove_team_member(Auth, design.id, grace)
      assert_received {:organization_event, :remove_team_member}
      assert team_members(design) == []

      {:ok, _team} = Organization.remove_team(Auth, design.id)
      assert_received {:organization_event, :delete_team}

      assert {:error, %{code: :cannot_remove_last_team}} =
               Organization.remove_team(Auth, ops.id)

      assert Repo.aggregate("teams", :count) == 1
    end
  end

  describe "invitations" do
    test "sent, refused, resent, accepted and canceled", %{browser: _browser} do
      ada = user_id("ada@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada)
      {:ok, other} = Organization.create_organization(Auth, %{name: "Other", slug: "other"}, ada)
      {:ok, design} = Organization.create_team(Auth, org.id, %{name: "Design"})
      {:ok, elsewhere} = Organization.create_team(Auth, other.id, %{name: "Elsewhere"})

      {:ok, invitation} =
        Organization.invite_member(Auth, org.id, " Grace@Example.com ", "admin", ada)

      assert {invitation.email, invitation.role, invitation.status, invitation.inviter_id} ==
               {"grace@example.com", "admin", "pending", ada}

      assert_received {:organization_event, :create_invitation}
      id = invitation.id

      assert_received {:invitation, "grace@example.com", ^id, "admin", "ada@example.com",
                       "http://localhost:4000"}

      # Refused: the same checks as the endpoint.
      for {email, role, opts, code} <- [
            {"grace@example.com", "member", [], :already_invited},
            {"not-an-email", "member", [], :invalid_email},
            {"alan@example.com", "emperor", [], :invalid_role},
            {"ada@example.com", "member", [], :already_member},
            {"alan@example.com", "member", [team_id: elsewhere.id], :team_not_found},
            {"alan@example.com", "member", [team_id: "not-an-id"], :team_not_found}
          ] do
        assert {:error, %{code: ^code}} =
                 Organization.invite_member(Auth, org.id, email, role, ada, opts)
      end

      refute_received {:invitation, _email, _id, _role, _inviter, _base_url}

      assert_raise ArgumentError, fn ->
        Organization.invite_member(Auth, org.id, "alan@example.com", "member", ada, team: "x")
      end

      # Resending refreshes the pending invitation.
      {:ok, resent} =
        Organization.invite_member(Auth, org.id, "grace@example.com", "member", ada, resend: true)

      assert {resent.id, resent.role} == {id, "member"}
      assert_received {:invitation, "grace@example.com", ^id, "member", _inviter, _base_url}

      # Invited into a team: accepting joins both.
      {:ok, _invitation} =
        Organization.invite_member(Auth, org.id, "alan@example.com", "member", ada,
          team_id: design.id
        )

      assert_received {:invitation, "alan@example.com", alan_invitation, _role, _inviter,
                       _base_url}

      {alan_browser, _alan} = user("alan@example.com")

      {_alan_browser, conn} =
        post(alan_browser, "/organization/accept-invitation", %{invitation_id: alan_invitation})

      assert json(conn)["member"]["role"] == "member"
      assert team_members(design) == ["alan@example.com"]

      # Canceled: only pending ones, and then nobody accepts it.
      {:ok, canceled} = Organization.cancel_invitation(Auth, id)
      assert canceled.status == "canceled"
      assert_received {:organization_event, :cancel_invitation}

      assert {:error, %{code: :invitation_not_found}} = Organization.cancel_invitation(Auth, id)

      assert {:error, %{code: :invitation_not_found}} =
               Organization.cancel_invitation(Auth, alan_invitation)

      {grace_browser, _grace} = user("grace@example.com")

      {_grace_browser, conn} =
        post(grace_browser, "/organization/accept-invitation", %{invitation_id: id})

      assert json(conn)["error"]["code"] == "invitation_not_found"

      assert members(org) == [{"ada@example.com", "owner"}, {"alan@example.com", "member"}]
    end

    test "the limit on pending invitations applies", %{browser: _browser} do
      ada = user_id("ada@example.com")
      {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada)

      [first | _rest] =
        for email <- ~w(grace@example.com alan@example.com eve@example.com) do
          {:ok, invitation} = Organization.invite_member(Auth, org.id, email, "member", ada)
          invitation
        end

      assert {:error, %{code: :invitation_limit_reached}} =
               Organization.invite_member(Auth, org.id, "bob@example.com", "member", ada)

      # Canceling one makes room.
      {:ok, _canceled} = Organization.cancel_invitation(Auth, first.id)

      assert {:ok, _invitation} =
               Organization.invite_member(Auth, org.id, "bob@example.com", "member", ada)
    end
  end
end

defmodule Authmk.OrganizationServerWithoutTeamsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Organization
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Organization]
  end

  @moduletag auth: Auth

  test "team functions and invitations need their options", %{browser: browser} do
    {_browser, ada} = sign_up(browser, %{email: "ada@example.com"})
    {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, ada["id"])
    id = Ecto.UUID.generate()

    for result <- [
          Organization.create_team(Auth, org.id, %{name: "Design"}),
          Organization.update_team(Auth, id, %{name: "UX"}),
          Organization.remove_team(Auth, id),
          Organization.add_team_member(Auth, id, ada["id"]),
          Organization.remove_team_member(Auth, id, ada["id"]),
          # No `send_invitation_email`.
          Organization.invite_member(Auth, org.id, "grace@example.com", "member", ada["id"])
        ] do
      assert {:error, %{code: :feature_disabled}} = result
    end

    {_browser, grace} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    {:ok, member} = Organization.add_member(Auth, org.id, grace["id"], "member")
    assert member.role == "member"
  end
end
