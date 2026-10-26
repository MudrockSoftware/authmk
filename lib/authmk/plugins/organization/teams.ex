defmodule Authmk.Plugins.Organization.Teams do
  @moduledoc false
  # Team endpoints: create, update, remove, list, the active team, and team
  # members. Only with `teams: [enabled: true]`.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{Context, Input, Serializer, Store}
  alias Authmk.Plugins.Organization.{Access, Config, Errors, Hooks, Organizations}

  def create(%Context{params: params} = ctx) do
    opts = Config.opts(ctx)[:teams]

    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.authorize(ctx, id, team: [:create]),
         :ok <- under(opts[:maximum_teams], team_count(ctx, organization), :team_limit_reached),
         attrs =
           Map.merge(Input.attrs(ctx, :team), %{
             "name" => params.name,
             "organization_id" => organization.id
           }),
         {:ok, attrs} <- Hooks.before_event(ctx, :create_team, attrs),
         {:ok, team} <- Store.insert(ctx, :team, attrs) do
      :ok = Hooks.after_event(ctx, :create_team, team)
      {:ok, serialize(ctx, team), ctx}
    end
  end

  def update(%Context{params: params} = ctx) do
    with {:ok, team} <- fetch(ctx, params.team_id),
         {:ok, _organization, _member} <-
           Access.authorize(ctx, team.organization_id, team: [:update]),
         attrs =
           Map.drop(Input.attrs(%{ctx | raw_params: params.data}, :team), ["organization_id"]),
         {:ok, attrs} <- Hooks.before_event(ctx, :update_team, attrs),
         {:ok, team} <- Store.update(ctx, :team, team, attrs) do
      :ok = Hooks.after_event(ctx, :update_team, team)
      {:ok, serialize(ctx, team), ctx}
    end
  end

  def remove(%Context{params: params} = ctx) do
    opts = Config.opts(ctx)[:teams]

    with {:ok, team} <- fetch(ctx, params.team_id),
         {:ok, organization, _member} <-
           Access.authorize(ctx, team.organization_id, team: [:delete]),
         :ok <- keeps_a_team(ctx, organization, opts),
         {:ok, team} <- Hooks.before_event(ctx, :delete_team, team),
         {:ok, team} <- Store.delete(ctx, :team, team) do
      :ok = Hooks.after_event(ctx, :delete_team, team)
      {:ok, %{status: true}, ctx}
    end
  end

  def list(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.member_of(ctx, id) do
      teams = Store.all(ctx, :team, organization_id: organization.id)
      {:ok, Enum.map(teams, &serialize(ctx, &1)), ctx}
    end
  end

  def list_for_user(%Context{user: user} = ctx) do
    team = Store.module(ctx, :team)
    team_member = Store.module(ctx, :team_member)

    query =
      from(t in team,
        join: tm in ^team_member,
        on: tm.team_id == t.id,
        where: tm.user_id == ^user.id
      )

    {:ok, ctx |> Store.list(:team, query) |> Enum.map(&serialize(ctx, &1)), ctx}
  end

  # `team_id: nil` clears it. The team must be in the active organization,
  # and the user in the team.
  def set_active(%Context{params: %{team_id: nil}} = ctx), do: set_session(ctx, nil, nil)

  def set_active(%Context{params: params, user: user} = ctx) do
    with {:ok, team} <- fetch(ctx, params.team_id),
         {:ok, _organization, _member} <- Access.member_of(ctx, team.organization_id),
         :ok <- in_team(ctx, team, user) do
      set_session(ctx, team, serialize(ctx, team))
    end
  end

  def members(%Context{params: params} = ctx) do
    with {:ok, team_id} <- team_id(ctx, params.team_id),
         {:ok, team} <- fetch(ctx, team_id),
         {:ok, _organization, _member} <- Access.member_of(ctx, team.organization_id) do
      team_members = Store.all(ctx, :team_member, team_id: team.id)
      {:ok, Enum.map(team_members, &Serializer.record(ctx, :team_member, &1)), ctx}
    end
  end

  # Members of the organization only.
  def add_member(%Context{params: params} = ctx) do
    opts = Config.opts(ctx)[:teams]

    with {:ok, team} <- fetch(ctx, params.team_id),
         {:ok, organization, _member} <-
           Access.authorize(ctx, team.organization_id, member: [:update]),
         %{} <-
           Store.get_by(ctx, :member, organization_id: organization.id, user_id: params.user_id),
         :ok <-
           under(
             opts[:maximum_members_per_team],
             member_count(ctx, team),
             :team_member_limit_reached
           ),
         attrs = %{team_id: team.id, user_id: params.user_id},
         {:ok, attrs} <- Hooks.before_event(ctx, :add_team_member, attrs),
         {:ok, team_member} <- Store.insert(ctx, :team_member, attrs) do
      :ok = Hooks.after_event(ctx, :add_team_member, team_member)
      {:ok, Serializer.record(ctx, :team_member, team_member), ctx}
    else
      nil -> {:error, Errors.error(:member_not_found)}
      error -> error
    end
  end

  def remove_member(%Context{params: params} = ctx) do
    with {:ok, team} <- fetch(ctx, params.team_id),
         {:ok, _organization, _member} <-
           Access.authorize(ctx, team.organization_id, member: [:update]),
         %{} = team_member <-
           Store.get_by(ctx, :team_member, team_id: team.id, user_id: params.user_id),
         {:ok, team_member} <- Hooks.before_event(ctx, :remove_team_member, team_member),
         {:ok, team_member} <- Store.delete(ctx, :team_member, team_member) do
      :ok = Hooks.after_event(ctx, :remove_team_member, team_member)
      {:ok, %{status: true}, ctx}
    else
      nil -> {:error, Errors.error(:member_not_found)}
      error -> error
    end
  end

  defp team_id(%Context{session: session}, nil) do
    case Map.get(session, :active_team_id) do
      nil -> {:error, Errors.error(:team_not_found)}
      id -> {:ok, id}
    end
  end

  defp team_id(_ctx, id), do: {:ok, id}

  defp set_session(ctx, team, body) do
    with {:ok, ctx} <-
           Organizations.set_session(ctx, %{active_team_id: team && to_string(team.id)}) do
      {:ok, body, ctx}
    end
  end

  defp in_team(ctx, team, user) do
    if Store.get_by(ctx, :team_member, team_id: team.id, user_id: user.id),
      do: :ok,
      else: {:error, Errors.error(:member_not_found)}
  end

  defp keeps_a_team(ctx, organization, opts) do
    if opts[:allow_removing_all_teams] or team_count(ctx, organization) > 1,
      do: :ok,
      else: {:error, Errors.error(:cannot_remove_last_team)}
  end

  defp team_count(ctx, organization),
    do:
      Store.count(
        ctx,
        :team,
        from(t in Store.module(ctx, :team), where: t.organization_id == ^organization.id)
      )

  defp member_count(ctx, team),
    do:
      Store.count(
        ctx,
        :team_member,
        from(tm in Store.module(ctx, :team_member), where: tm.team_id == ^team.id)
      )

  defp under(nil, _count, _code), do: :ok
  defp under(limit, count, _code) when count < limit, do: :ok
  defp under(_limit, _count, code), do: {:error, Errors.error(code)}

  defp fetch(ctx, id) do
    case Store.get_by(ctx, :team, id: id) do
      nil -> {:error, Errors.error(:team_not_found)}
      team -> {:ok, team}
    end
  rescue
    Ecto.Query.CastError -> {:error, Errors.error(:team_not_found)}
  end

  defp serialize(ctx, team), do: Serializer.record(ctx, :team, team)
end
