defmodule PhoenixAppWeb.GateTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Authmk.Plugins.{Gate, Organization}
  alias Authmk.Testing

  test "teams decide who sees an organization's invoices, member roles what they do", %{
    conn: conn
  } do
    owner = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")
    grace = Testing.create_user(PhoenixApp.Auth, email: "grace@example.com")
    alan = Testing.create_user(PhoenixApp.Auth, email: "alan@example.com")

    # The app sets Acme up, as its own admin pages would.
    {:ok, acme} =
      Organization.create_organization(PhoenixApp.Auth, %{name: "Acme", slug: "acme"}, owner.id)

    {:ok, globex} =
      Organization.create_organization(
        PhoenixApp.Auth,
        %{name: "Globex", slug: "globex"},
        owner.id
      )

    {:ok, _member} = Organization.add_member(PhoenixApp.Auth, acme.id, grace.id, "member")
    {:ok, team} = Organization.create_team(PhoenixApp.Auth, acme.id, %{name: "Finance"})
    {:ok, _team} = Gate.set_team_role(PhoenixApp.Auth, team.id, "finance")
    {:ok, _team_member} = Organization.add_team_member(PhoenixApp.Auth, team.id, grace.id)

    # Grace is an employee of Finance: she sees invoices, without approving.
    grace_conn = Testing.sign_in(conn, PhoenixApp.Auth, grace)
    {:ok, view, html} = live(grace_conn, ~p"/orgs/#{acme.id}/invoices")
    assert html =~ "Invoices"
    refute has_element?(view, "#approve")

    # As a manager, she approves.
    {:ok, _team_member} = Gate.set_team_member_role(PhoenixApp.Auth, team.id, grace.id, "manager")
    {:ok, view, _html} = live(grace_conn, ~p"/orgs/#{acme.id}/invoices")
    assert view |> element("#approve") |> render_click() =~ "Approved"

    # Not in Globex, by URL or by patching.
    assert {:error, {:redirect, %{to: "/settings"}}} =
             live(grace_conn, ~p"/orgs/#{globex.id}/invoices")

    assert {:error, {:redirect, %{to: "/settings"}}} =
             render_patch(view, ~p"/orgs/#{globex.id}/invoices")

    # Outsiders and visitors don't get in; the owner does.
    alan_conn = Testing.sign_in(build_conn(), PhoenixApp.Auth, alan)

    assert {:error, {:redirect, %{to: "/settings"}}} =
             live(alan_conn, ~p"/orgs/#{acme.id}/invoices")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(build_conn(), ~p"/orgs/#{acme.id}/invoices")

    owner_conn = Testing.sign_in(build_conn(), PhoenixApp.Auth, owner)
    {:ok, view, _html} = live(owner_conn, ~p"/orgs/#{globex.id}/invoices")
    assert has_element?(view, "#approve")
  end
end
