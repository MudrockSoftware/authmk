defmodule Authmk.DashboardOrganizationsTest do
  # Managing organizations from the dashboard, as an app admin who isn't a
  # member: the Organization plugin's rules hold (an owner always stays,
  # roles must exist), and every change is in the audit log.
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.Testing

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      schema: [organization: [additional_fields: [billing_email: [type: :string]]]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        Authmk.Plugins.AuditLog,
        {Authmk.Plugins.Organization,
         teams: [enabled: true], send_invitation_email: &__MODULE__.send_invitation/2}
      ]

    def send_invitation(data, _ctx), do: send(self(), {:invitation, data.email, data.role})
  end

  @moduletag auth: Auth

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", name: "Admin", role: "admin")}
  end

  test "create, edit, members and roles, teams, invitations, delete", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com", name: "Ada")
    grace = Testing.create_user(Auth, email: "grace@example.com", name: "Grace")

    assert {400, _} =
             post_json(Auth, "organizations", admin, %{
               name: "Acme",
               slug: "acme",
               owner_email: "nobody@example.com"
             })

    {200, %{"id" => id}} =
      post_json(Auth, "organizations", admin, %{
        name: "Acme",
        slug: "acme",
        owner_email: "ada@example.com",
        fields: %{billing_email: "billing@acme.example"}
      })

    {200, detail} = get_json(Auth, "organizations/#{id}", admin)
    assert detail["organization"]["fields"] == %{"billing_email" => "billing@acme.example"}
    assert [%{"role" => "owner", "user" => %{"email" => "ada@example.com"}}] = detail["members"]
    assert Enum.map(detail["roles"], & &1["name"]) == ["admin", "member", "owner"]

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/update", admin, %{
               name: "Acme Inc",
               slug: "acme-inc"
             })

    # Members, with roles that exist only.
    assert {400, _} =
             post_json(Auth, "organizations/#{id}/members", admin, %{
               email: "grace@example.com",
               role: "wizard"
             })

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/members", admin, %{
               email: "grace@example.com",
               role: "member"
             })

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/members/#{grace.id}/role", admin, %{
               role: "admin"
             })

    # The last owner stays.
    assert {_status, %{"error" => %{"code" => "cannot_remove_last_owner"}}} =
             post_json(Auth, "organizations/#{id}/members/#{ada.id}/remove", admin)

    # Teams.
    {200, _} = post_json(Auth, "organizations/#{id}/teams", admin, %{name: "Platform"})
    {200, detail} = get_json(Auth, "organizations/#{id}", admin)
    [%{"id" => team_id}] = detail["teams"]

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/teams/#{team_id}/members", admin, %{
               user_id: to_string(grace.id)
             })

    {200, detail} = get_json(Auth, "organizations/#{id}", admin)

    assert [%{"name" => "Platform", "members" => [%{"email" => "grace@example.com"}]}] =
             detail["teams"]

    assert {200, _} =
             post_json(
               Auth,
               "organizations/#{id}/teams/#{team_id}/members/#{grace.id}/remove",
               admin
             )

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/teams/#{team_id}/update", admin, %{name: "Core"})

    # Invitations: sent through the app's sender.
    assert {200, _} =
             post_json(Auth, "organizations/#{id}/invitations", admin, %{
               email: "Linus@Example.com",
               role: "member"
             })

    assert_received {:invitation, "linus@example.com", "member"}
    {200, detail} = get_json(Auth, "organizations/#{id}", admin)
    [%{"id" => invitation_id, "status" => "pending"}] = detail["invitations"]

    assert {200, _} =
             post_json(Auth, "organizations/#{id}/invitations/#{invitation_id}/cancel", admin)

    assert {200, %{"organizations" => [%{"name" => "Acme Inc", "members" => 2}]}} =
             get_json(Auth, "organizations?search=INC", admin)

    assert {200, _} = post_json(Auth, "organizations/#{id}/members/#{grace.id}/remove", admin)
    assert {200, _} = post_json(Auth, "organizations/#{id}/delete", admin)
    assert {404, _} = get_json(Auth, "organizations/#{id}", admin)

    events = Enum.map(dashboard_events(Auth), & &1.event)

    for event <- ~w(organization.created organization.updated member.added member.role_set
                    team.created team_member.added invitation.created invitation.canceled
                    member.removed organization.deleted) do
      assert ("dashboard." <> event) in events
    end
  end

  test "a team or invitation from another organization isn't found", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com")

    {200, %{"id" => acme}} =
      post_json(Auth, "organizations", admin, %{
        name: "Acme",
        slug: "acme",
        owner_email: ada.email
      })

    {200, %{"id" => other}} =
      post_json(Auth, "organizations", admin, %{
        name: "Other",
        slug: "other",
        owner_email: ada.email
      })

    {200, _} = post_json(Auth, "organizations/#{other}/teams", admin, %{name: "Theirs"})
    {200, %{"teams" => [%{"id" => team_id}]}} = get_json(Auth, "organizations/#{other}", admin)

    assert {404, _} = post_json(Auth, "organizations/#{acme}/teams/#{team_id}/remove", admin)
    assert {404, _} = post_json(Auth, "organizations/#{acme}/invitations/nope/cancel", admin)
  end

  test "managing organizations needs its Admin permissions" do
    support = Testing.create_user(Auth, email: "support@example.com", role: "user")
    assert {403, _} = post_json(Auth, "organizations", support, %{name: "X", slug: "x"})
  end
end
