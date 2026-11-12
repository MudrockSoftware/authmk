defmodule PlugApp.GateTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  defp sign_up(email) do
    conn =
      post_json("/auth/sign-up/email", %{email: email, password: "correct horse", name: "User"})

    {cookies(conn), json(conn)["user"]}
  end

  test "a team's role decides who sees an organization's invoices" do
    {owner, _owner} = sign_up("ada@example.com")
    conn = post_json("/auth/organization/create", %{name: "Acme", slug: "acme"}, owner)
    owner = Map.merge(owner, cookies(conn))
    org = json(conn)

    # Grace joins (the app adds her, as after an invitation) and the owner
    # puts her in a Finance team.
    {grace, grace_user} = sign_up("grace@example.com")

    {:ok, _member} =
      Authmk.Plugins.Organization.add_member(PlugApp.Auth, org["id"], grace_user["id"], "member")

    {stranger, _user} = sign_up("alan@example.com")

    conn =
      post_json(
        "/auth/organization/create-team",
        %{organization_id: org["id"], name: "Finance"},
        owner
      )

    team = json(conn)

    conn =
      post_json(
        "/auth/organization/add-team-member",
        %{team_id: team["id"], user_id: grace_user["id"]},
        owner
      )

    # New team members are employees (default_team_member_role).
    assert json(conn)["role"] == "employee"

    page = "/orgs/#{org["id"]}/invoices"
    assert get_path(page, grace).status == 403

    # The owner gives the team its role: Grace may view invoices now.
    conn = post_json("/auth/gate/set-team-role", %{team_id: team["id"], role: "finance"}, owner)
    assert json(conn)["role"] == "finance"
    assert get_path(page, grace).status == 200
    assert get_path(page, owner).status == 200

    # What Grace may do, for the app's menus: employees only view.
    conn = get_path("/auth/gate/abilities?organization_id=#{org["id"]}", grace)
    assert json(conn)["abilities"] == %{"invoice" => ["view"], "report" => ["view"]}

    # Acme decides its employees don't see invoices.
    conn =
      post_json(
        "/auth/gate/set-role",
        %{
          organization_id: org["id"],
          level: "team_member",
          role: "employee",
          permission: %{report: ["view"]}
        },
        owner
      )

    assert json(conn)["source"] == "override"
    assert get_path(page, grace).status == 403

    # Grace can't change that herself, and outsiders see nothing.
    conn =
      post_json(
        "/auth/gate/delete-role",
        %{organization_id: org["id"], level: "team_member", role: "employee"},
        grace
      )

    assert conn.status == 403
    assert get_path(page, stranger).status == 403
    assert get_path(page, %{}).status == 401
  end
end
