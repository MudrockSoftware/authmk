defmodule Authmk.Dashboard.Data.Permissions do
  @moduledoc false
  # What a user can see and do, and where each permission comes from: their
  # app roles (Authmk.Plugins.Admin), `admin_user_ids`, and in each
  # organization their member roles, built in or the organization's own
  # (Authmk.Plugins.Organization), and the teams they're in. Worked out with
  # the same access control the plugins check, so it shows what they allow.

  import Ecto.Query

  alias Authmk.{AccessControl, Context, Store}
  alias Authmk.Dashboard.Data
  alias Authmk.Plugins.{Admin, Organization}
  alias Authmk.Plugins.Organization.Access, as: OrganizationAccess

  def of(ctx, user) do
    %{app: app(ctx, user), organizations: organizations(ctx, user)}
  end

  defp app(ctx, user) do
    if Data.enabled?(ctx, Admin) do
      opts = Context.plugin_opts(ctx, Admin)
      access_control = opts[:access_control].access_control()
      roles = AccessControl.parse_roles(Map.get(user, :role))

      %{
        roles: Enum.map(roles, &role(access_control, &1, "app role")),
        all_admin_actions: to_string(user.id) in opts[:admin_user_ids]
      }
    end
  end

  defp organizations(ctx, user) do
    if Data.model?(ctx, :member) do
      ctx = Context.put_private(ctx, :organization_plugin, Organization)
      teams = teams(ctx, user)

      for {organization, member} <- memberships(ctx, user) do
        access_control = OrganizationAccess.access_control(ctx, organization)
        built_in = Context.plugin_opts(ctx, Organization)[:access_control].role_names()

        %{
          id: to_string(organization.id),
          name: organization.name,
          slug: organization.slug,
          roles:
            for name <- AccessControl.parse_roles(member.role) do
              source = if name in built_in, do: "built-in role", else: "organization's own role"
              role(access_control, name, source)
            end,
          teams: Map.get(teams, to_string(organization.id), []),
          joined_at: member.inserted_at
        }
      end
    else
      []
    end
  end

  # A role and what it grants. A role that no longer exists grants nothing.
  defp role(access_control, name, source) do
    grants =
      for {resource, actions} <- AccessControl.granted(access_control, name),
          MapSet.size(actions) > 0,
          into: %{},
          do: {resource, actions |> MapSet.to_list() |> Enum.sort()}

    %{
      name: name,
      source: source,
      exists: AccessControl.valid_roles?(access_control, name),
      permissions: grants
    }
  end

  defp memberships(ctx, user) do
    Store.list(
      ctx,
      :member,
      from(m in Store.module(ctx, :member),
        join: o in ^Store.module(ctx, :organization),
        on: o.id == m.organization_id,
        where: m.user_id == ^user.id,
        order_by: [asc: m.inserted_at],
        select: {o, m},
        limit: 200
      )
    )
  end

  # The user's teams, by organization id.
  defp teams(ctx, user) do
    if Data.model?(ctx, :team_member) do
      ctx
      |> Store.list(
        :team_member,
        from(tm in Store.module(ctx, :team_member),
          join: t in ^Store.module(ctx, :team),
          on: t.id == tm.team_id,
          where: tm.user_id == ^user.id,
          select: t,
          limit: 500
        )
      )
      |> Enum.group_by(
        &to_string(&1.organization_id),
        &%{id: to_string(&1.id), name: &1.name}
      )
    else
      %{}
    end
  end
end
