defmodule Authmk.Plugins.Gate.Check do
  @moduledoc false
  # What a user may do on a resource, read from the database on every
  # check: nothing is cached, so a role taken away stops working at once.
  #
  #   1. A banned or missing user may do nothing.
  #   2. An app admin may do everything.
  #   3. App roles grant what the code says, everywhere.
  #   4. In the resource's organization: an organization admin may do
  #      everything but app-only abilities. Other members get what their
  #      member roles grant, plus, for each of their teams there (only the
  #      resource's team, when it has one), what the team's role grants,
  #      narrowed by their role in the team.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{AccessControl, Context, Store}
  alias Authmk.Plugins.{Admin, Organization}
  alias Authmk.Plugins.Gate.{Roles, Rules}

  @doc """
  Everything `user` may do in `scope` (see Authmk.Plugins.Gate.Scope), as
  `%{resource => MapSet of action}`. `opts` are the plugin's.
  """
  def granted(%Context{} = ctx, opts, user, scope) do
    case fetch_user(ctx, user) do
      nil -> %{}
      user -> granted_to(ctx, opts, user, scope)
    end
  end

  defp granted_to(ctx, opts, user, scope) do
    rules = opts[:rules]

    cond do
      banned?(user) ->
        %{}

      app_admin?(ctx, user) ->
        Rules.everything(rules)

      true ->
        rules
        |> Rules.level(:app)
        |> AccessControl.granted(user.role)
        |> Rules.union(in_organization(ctx, opts, user, scope))
    end
  end

  defp in_organization(ctx, opts, user, {:organization, organization_id, team_id}) do
    with true <- organizations?(ctx),
         %{} = member <- membership(ctx, organization_id, user) do
      if organization_admin?(opts, member),
        do: Rules.organization_wide(opts[:rules]),
        else: member_grants(ctx, opts[:rules], member, team_id)
    else
      _not_a_member -> %{}
    end
  end

  defp in_organization(_ctx, _opts, _user, _app_or_nowhere), do: %{}

  defp member_grants(ctx, rules, member, team_id) do
    roles = Roles.effective(ctx, rules, member.organization_id)
    from_member_roles = Roles.grants(roles.organization, member.role)

    ctx
    |> teams(member, team_id)
    |> Enum.map(fn {team_role, member_role} -> team_grants(roles, team_role, member_role) end)
    |> Enum.reduce(from_member_roles, &Rules.union/2)
  end

  # A team without a role grants nothing. A member without a role gets all
  # the team has; a member's role only narrows it.
  defp team_grants(_roles, nil, _member_role), do: %{}

  defp team_grants(roles, team_role, member_role) do
    team = Map.get(roles.team, team_role, %{})

    case member_role do
      nil -> team
      role -> Rules.intersect(team, Map.get(roles.team_member, role, %{}))
    end
  end

  # {team role, member role} for each of the member's teams in their
  # organization, or only in `team_id`.
  defp teams(ctx, member, team_id) do
    if Map.has_key?(ctx.config.schema.models, :team) do
      query =
        from(tm in Store.module(ctx, :team_member),
          join: t in ^Store.module(ctx, :team),
          on: t.id == tm.team_id,
          where: tm.user_id == ^member.user_id and t.organization_id == ^member.organization_id,
          select: {t.role, tm.role}
        )

      query = if team_id, do: from([tm, t] in query, where: t.id == ^team_id), else: query
      Store.list(ctx, :team_member, query)
    else
      []
    end
  end

  @doc "`user`'s membership in an organization, or `nil`."
  def membership(ctx, organization_id, user) do
    Store.get_by(ctx, :member, organization_id: organization_id, user_id: user.id)
  rescue
    # Not an id this database could have: no such organization.
    Ecto.Query.CastError -> nil
  end

  defp fetch_user(ctx, %{id: id}) when not is_nil(id) do
    Store.get_by(ctx, :user, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp fetch_user(_ctx, _user), do: nil

  @doc "Whether `user` (a user record) is an app admin, by Authmk.Plugins.Admin's options."
  def app_admin?(ctx, user) do
    opts = Context.plugin_opts(ctx, Admin)

    to_string(user.id) in opts[:admin_user_ids] or
      Enum.any?(AccessControl.parse_roles(user.role), &(&1 in opts[:admin_roles]))
  end

  @doc "Whether `member` is an admin of their organization."
  def organization_admin?(opts, member) do
    admin_roles = opts[:organization_admin_roles]
    Enum.any?(AccessControl.parse_roles(member.role), &(&1 in admin_roles))
  end

  defp banned?(user) do
    Map.get(user, :banned) == true and
      (is_nil(user.ban_expires) or DateTime.after?(user.ban_expires, DateTime.utc_now()))
  end

  defp organizations?(ctx), do: List.keymember?(ctx.config.plugins, Organization, 0)
end
