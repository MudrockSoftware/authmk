defmodule Authmk.Fuzz.GateAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.Admin,
      {Authmk.Plugins.Organization, teams: [enabled: true]},
      {Authmk.Plugins.Gate,
       abilities: [invoice: [:view, :update], billing: [:refund]],
       team_roles: [finance: [invoice: [:view, :update]]],
       team_member_roles: [employee: [invoice: [:view]]],
       app_only: [billing: [:refund]]}
    ]
end

defmodule Authmk.GateFuzzTest do
  # What organization admins send to change their access (role names,
  # levels, permissions) and the resources apps check: saved or refused,
  # never a crash, and never more than the code allows.
  use Authmk.EmulationCase, async: true
  use ExUnitProperties

  alias Authmk.Fuzz.GateAuth, as: Auth
  alias Authmk.Plugins.{Gate, Organization}
  alias Authmk.Test.Browser
  alias Authmk.Testing

  @moduletag :fuzz
  @moduletag auth: Auth

  @password "correct horse battery"

  setup do
    owner = Testing.create_user(Auth, email: "owner@example.com", password: @password)
    {:ok, org} = Organization.create_organization(Auth, %{name: "Acme", slug: "acme"}, owner.id)
    {:ok, team} = Organization.create_team(Auth, org.id, %{name: "Finance"})

    {browser, conn} =
      post(Browser.new(Auth), "/sign-in/email", %{
        email: "owner@example.com",
        password: @password
      })

    200 = conn.status
    %{browser: browser, org: org, team: team, owner: owner}
  end

  defp name do
    one_of([
      string(:printable, max_length: 70),
      member_of(["finance", "employee", "invoice", "view", "billing", "refund", "x"])
    ])
  end

  defp json_value do
    leaf = one_of([name(), integer(), boolean(), constant(nil)])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 3), map_of(name(), child, max_length: 3)])
    end)
  end

  defp permission do
    one_of([
      map_of(name(), one_of([list_of(name(), max_length: 3), json_value()]), max_length: 3),
      json_value()
    ])
  end

  property "roles from requests are saved or refused, and grant only what's allowed", ctx do
    check all(
            level <- one_of([member_of(["organization", "team", "team_member"]), name()]),
            role <- name(),
            permission <- permission()
          ) do
      {_browser, conn} =
        post(ctx.browser, "/gate/set-role", %{
          organization_id: ctx.org.id,
          level: level,
          role: role,
          permission: permission
        })

      assert conn.status in [200, 403, 422]
    end

    {:ok, roles} = Gate.list_roles(Auth, ctx.org.id)

    for %{permission: permission} <- roles, {resource, actions} <- permission do
      assert resource == "invoice"
      assert actions -- ["view", "update"] == []
    end
  end

  property "team and member roles from requests are set or refused", ctx do
    {:ok, _team_member} = Organization.add_team_member(Auth, ctx.team.id, ctx.owner.id)

    check all(
            team_role <- one_of([name(), constant(nil)]),
            member_role <- one_of([name(), constant(nil)])
          ) do
      {browser, conn} =
        post(ctx.browser, "/gate/set-team-role", %{team_id: ctx.team.id, role: team_role})

      assert conn.status in [200, 422]

      {_browser, conn} =
        post(browser, "/gate/set-team-member-role", %{
          team_id: ctx.team.id,
          user_id: ctx.owner.id,
          role: member_role
        })

      assert conn.status in [200, 422]
    end
  end

  property "checks on any resource answer true or false", ctx do
    grace = Testing.create_user(Auth, email: "grace@example.com")

    id = one_of([constant(ctx.org.id), constant(ctx.team.id), name(), integer(), constant(nil)])

    check all(
            resource <-
              one_of([
                fixed_map(%{organization_id: id}),
                fixed_map(%{team_id: id}),
                fixed_map(%{organization_id: id, team_id: id}),
                tuple({member_of([:organization, :team]), id})
              ])
          ) do
      assert is_boolean(Gate.allows?(Auth, grace, {:invoice, :view}, resource))
      assert Gate.allows?(Auth, ctx.owner, {:billing, :refund}, resource) == false
    end
  end
end
