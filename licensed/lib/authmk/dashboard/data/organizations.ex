defmodule Authmk.Dashboard.Data.Organizations do
  @moduledoc false
  # Organizations for the dashboard (with Authmk.Plugins.Organization): the
  # list, and one organization with its members, teams, invitations, roles,
  # SSO, SCIM and subscriptions.

  import Ecto.Query

  alias Authmk.{AccessControl, Context, Store}
  alias Authmk.Dashboard.Data
  alias Authmk.Dashboard.Data.Fields
  alias Authmk.Plugins.Organization
  alias Authmk.Plugins.Organization.Access, as: OrganizationAccess

  @doc "Organizations whose name or slug contains `search`, newest first, with member counts."
  def list(ctx, search, offset) do
    if Data.model?(ctx, :organization) do
      query =
        from(o in Store.module(ctx, :organization),
          order_by: [desc: o.inserted_at, desc: o.id],
          limit: ^(Data.page_size() + 1),
          offset: ^offset
        )

      organizations = Store.list(ctx, :organization, search(query, search))
      counts = member_counts(ctx, organizations)

      for organization <- organizations do
        organization
        |> organization()
        |> Map.put(:members, Map.get(counts, organization.id, 0))
      end
    else
      []
    end
  end

  @doc "Every organization's id and name, for filters (at most 500)."
  def options(ctx) do
    if Data.model?(ctx, :organization) do
      Store.list(
        ctx,
        :organization,
        from(o in Store.module(ctx, :organization), order_by: [asc: o.name], limit: 500)
      )
      |> Enum.map(&%{id: to_string(&1.id), name: &1.name})
    else
      []
    end
  end

  defp search(query, search) do
    case String.trim(search || "") do
      "" ->
        query

      term ->
        pattern = "%" <> Data.escape_like(String.downcase(term)) <> "%"

        where(
          query,
          [o],
          fragment("lower(?) LIKE ? ESCAPE '!'", o.name, ^pattern) or
            fragment("lower(?) LIKE ? ESCAPE '!'", o.slug, ^pattern)
        )
    end
  end

  # Only for the organizations on the page.
  defp member_counts(_ctx, []), do: %{}

  defp member_counts(ctx, organizations) do
    ids = Enum.map(organizations, & &1.id)

    from(m in Store.module(ctx, :member),
      where: m.organization_id in ^ids,
      group_by: m.organization_id,
      select: {m.organization_id, count(m.id)}
    )
    |> then(&Store.list(ctx, :member, &1))
    |> Map.new()
  end

  def find(ctx, id), do: Data.safe_get(ctx, :organization, id)

  def detail(ctx, organization) do
    ctx = Context.put_private(ctx, :organization_plugin, Organization)

    %{
      organization:
        Map.put(
          organization(organization),
          :fields,
          Fields.values(ctx, :organization, organization)
        ),
      fields: Fields.definitions(ctx, :organization),
      roles: roles(ctx, organization),
      members: members(ctx, organization),
      teams: teams(ctx, organization),
      invitations: Enum.map(by_organization(ctx, :invitation, organization), &invitation/1),
      sso_providers:
        Enum.map(by_organization(ctx, :sso_provider, organization), &Data.sso_provider/1),
      scim_connections:
        Enum.map(by_organization(ctx, :scim_connection, organization), &Data.scim_connection/1),
      subscriptions: subscriptions(ctx, organization)
    }
  end

  defp organization(organization) do
    %{
      id: to_string(organization.id),
      name: organization.name,
      slug: organization.slug,
      logo: Map.get(organization, :logo),
      created_at: organization.inserted_at
    }
  end

  # The roles members can have here: the built-in ones and the organization's own.
  defp roles(ctx, organization) do
    built_in = Context.plugin_opts(ctx, Organization)[:access_control].role_names()

    for name <- AccessControl.role_names(OrganizationAccess.access_control(ctx, organization)),
        do: %{name: name, built_in: name in built_in}
  end

  defp members(ctx, organization) do
    query =
      from(m in Store.module(ctx, :member),
        join: u in ^Store.module(ctx, :user),
        on: u.id == m.user_id,
        where: m.organization_id == ^organization.id,
        order_by: [asc: m.inserted_at],
        select: {u, m},
        limit: 500
      )

    for {user, member} <- Store.list(ctx, :member, query),
        do: %{user: Data.user(user), role: member.role, joined_at: member.inserted_at}
  end

  defp teams(ctx, organization) do
    teams = by_organization(ctx, :team, organization)
    members = team_members(ctx, teams)

    for team <- teams do
      %{
        id: to_string(team.id),
        name: team.name,
        members: Map.get(members, team.id, []),
        created_at: team.inserted_at
      }
    end
  end

  defp team_members(_ctx, []), do: %{}

  defp team_members(ctx, teams) do
    ids = Enum.map(teams, & &1.id)

    from(tm in Store.module(ctx, :team_member),
      join: u in ^Store.module(ctx, :user),
      on: u.id == tm.user_id,
      where: tm.team_id in ^ids,
      select: {tm.team_id, u},
      limit: 2000
    )
    |> then(&Store.list(ctx, :team_member, &1))
    |> Enum.group_by(&elem(&1, 0), fn {_team_id, user} ->
      %{id: to_string(user.id), email: user.email, name: user.name}
    end)
  end

  defp invitation(invitation) do
    %{
      id: to_string(invitation.id),
      email: invitation.email,
      role: invitation.role,
      status: invitation.status,
      team_id: Map.get(invitation, :team_id) && to_string(invitation.team_id),
      expires_at: invitation.expires_at,
      created_at: invitation.inserted_at
    }
  end

  defp subscriptions(ctx, organization) do
    if Data.model?(ctx, :subscription),
      do:
        Store.list(
          ctx,
          :subscription,
          from(s in Store.module(ctx, :subscription),
            where:
              s.reference_type == "organization" and
                s.reference_id == ^to_string(organization.id),
            order_by: [desc: s.inserted_at],
            limit: 20
          )
        )
        |> Enum.map(&Data.subscription/1),
      else: []
  end

  # Models that keep the organization's id as a reference (members, teams,
  # invitations) or as a string (SSO, SCIM): compared as each column is.
  defp by_organization(ctx, model, organization) do
    if Data.model?(ctx, model) do
      id = organization_id(ctx, model, organization)

      Store.list(
        ctx,
        model,
        from(r in Store.module(ctx, model),
          where: r.organization_id == ^id,
          order_by: [desc: r.inserted_at],
          limit: 500
        )
      )
    else
      []
    end
  end

  defp organization_id(ctx, model, organization) do
    field = Enum.find(ctx.config.schema.models[model].fields, &(&1.name == :organization_id))
    if field.references, do: organization.id, else: to_string(organization.id)
  end
end
