defmodule Authmk.Plugins.Organization.Members do
  @moduledoc false
  # Member endpoints: list, remove, update a role, the active member, leave.

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Authmk.{AccessControl, Context, Email, Serializer, Store}
  alias Authmk.Plugins.Organization.{Access, Config, Errors, Hooks}

  def list(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.member_of(ctx, id) do
      members = with_users(ctx, organization, limit: params.limit, offset: params.offset)
      total = Store.count(ctx, :member, members_query(ctx, organization))
      {:ok, %{members: members, total: total}, ctx}
    end
  end

  # By member id or by the member's email.
  def remove(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, actor} <- Access.authorize(ctx, id, member: [:delete]),
         {:ok, member} <- find_member(ctx, organization, params.member_id_or_email),
         :ok <- Access.check_owner_change(ctx, actor, member.role),
         :ok <- Access.check_not_last_owner(ctx, member),
         {:ok, member} <- remove_member(ctx, member) do
      {:ok, %{member: Serializer.record(ctx, :member, member)}, ctx}
    end
  end

  def update_role(%Context{params: params} = ctx) do
    role = role_string(params.role)

    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, actor} <- Access.authorize(ctx, id, member: [:update]),
         {:ok, member} <- find_member(ctx, organization, params.member_id),
         :ok <- valid_role(ctx, organization, role),
         # Taking or giving the owner role takes an owner.
         :ok <- Access.check_owner_change(ctx, actor, member.role),
         :ok <- Access.check_owner_change(ctx, actor, role),
         :ok <- not_demoting_last_owner(ctx, member, role),
         {:ok, attrs} <- Hooks.before_event(ctx, :update_member_role, %{role: role}),
         {:ok, member} <- Store.update(ctx, :member, member, attrs) do
      :ok = Hooks.after_event(ctx, :update_member_role, member)
      {:ok, %{member: Serializer.record(ctx, :member, member)}, ctx}
    end
  end

  def active_member(%Context{user: user} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, nil),
         {:ok, _organization, member} <- Access.member_of(ctx, id) do
      {:ok, Map.put(Serializer.record(ctx, :member, member), :user, Serializer.user(ctx, user)),
       ctx}
    end
  end

  def active_member_role(ctx) do
    with {:ok, id} <- Access.organization_id(ctx, nil),
         {:ok, _organization, member} <- Access.member_of(ctx, id) do
      {:ok, %{role: member.role}, ctx}
    end
  end

  def leave(%Context{params: params} = ctx) do
    with {:ok, _organization, member} <- Access.member_of(ctx, params.organization_id),
         :ok <- Access.check_not_last_owner(ctx, member),
         {:ok, member} <- remove_member(ctx, member) do
      {:ok, %{member: Serializer.record(ctx, :member, member)}, ctx}
    end
  end

  @doc "Sets a member's role, for server code: same checks as the endpoint, minus the actor's."
  def set_role(ctx, organization, user, role) do
    with %{} = member <-
           Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id),
         :ok <- valid_role(ctx, organization, role),
         :ok <- not_demoting_last_owner(ctx, member, role),
         {:ok, attrs} <- Hooks.before_event(ctx, :update_member_role, %{role: role}),
         {:ok, member} <- Store.update(ctx, :member, member, attrs) do
      :ok = Hooks.after_event(ctx, :update_member_role, member)
      {:ok, member}
    else
      nil -> {:error, Errors.error(:member_not_found)}
      error -> error
    end
  end

  @doc "Removes a user from an organization, for server code."
  def remove_user(ctx, organization, user) do
    case Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id) do
      nil ->
        {:error, Errors.error(:member_not_found)}

      member ->
        with :ok <- Access.check_not_last_owner(ctx, member), do: remove_member(ctx, member)
    end
  end

  @doc """
  Adds `user` to `organization` with `role`, within the membership limit.
  Runs the `:add_member` hooks.
  """
  def add(ctx, organization, user, role) do
    opts = Config.opts(ctx)

    with :ok <- not_member(ctx, organization, user),
         :ok <- under_limit(ctx, organization, opts) do
      insert(ctx, organization, user, role)
    end
  end

  @doc false
  def insert(ctx, organization, user, role) do
    attrs = %{organization_id: organization.id, user_id: user.id, role: role}

    with {:ok, attrs} <- Hooks.before_event(ctx, :add_member, attrs),
         {:ok, member} <- Store.insert(ctx, :member, attrs) do
      :ok = Hooks.after_event(ctx, :add_member, member)
      {:ok, member}
    end
  end

  @doc "Members with their user, oldest first."
  def with_users(ctx, organization, opts) do
    query = members_query(ctx, organization)
    query = if opts[:limit], do: from(m in query, limit: ^opts[:limit]), else: query
    query = if opts[:offset], do: from(m in query, offset: ^opts[:offset]), else: query
    members = Store.list(ctx, :member, query)
    users = users_by_id(ctx, Enum.map(members, & &1.user_id))

    Enum.map(members, fn member ->
      ctx
      |> Serializer.record(:member, member)
      |> Map.put(:user, Serializer.user(ctx, Map.get(users, member.user_id)))
    end)
  end

  defp members_query(ctx, organization) do
    member = Store.module(ctx, :member)

    from(m in member,
      where: m.organization_id == ^organization.id,
      order_by: [asc: m.inserted_at]
    )
  end

  defp users_by_id(ctx, ids) do
    user = Store.module(ctx, :user)
    ctx |> Store.list(:user, from(u in user, where: u.id in ^ids)) |> Map.new(&{&1.id, &1})
  end

  defp remove_member(ctx, member) do
    with {:ok, member} <- Hooks.before_event(ctx, :remove_member, member),
         {:ok, member} <- Store.delete(ctx, :member, member) do
      :ok = remove_from_teams(ctx, member)
      :ok = Hooks.after_event(ctx, :remove_member, member)
      {:ok, member}
    end
  end

  # Leaving an organization means leaving its teams.
  defp remove_from_teams(ctx, member) do
    if Config.opts(ctx)[:teams][:enabled], do: delete_team_memberships(ctx, member)
    :ok
  end

  defp delete_team_memberships(ctx, member) do
    team = Store.module(ctx, :team)
    query = from(t in team, where: t.organization_id == ^member.organization_id, select: t.id)
    team_ids = Store.list(ctx, :team, query)
    condition = dynamic([tm], tm.user_id == ^member.user_id and tm.team_id in ^team_ids)
    _count = Store.delete_all(ctx, :team_member, condition)
    :ok
  end

  defp find_member(ctx, organization, id_or_email) do
    member =
      if is_binary(id_or_email) and String.contains?(id_or_email, "@") do
        case Store.get_by(ctx, :user, email: Email.normalize(id_or_email)) do
          nil -> nil
          user -> Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id)
        end
      else
        safe_get(ctx, organization, id_or_email)
      end

    if member, do: {:ok, member}, else: {:error, Errors.error(:member_not_found)}
  end

  defp safe_get(ctx, organization, id) do
    Store.get_by(ctx, :member, id: id, organization_id: organization.id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp not_demoting_last_owner(ctx, member, role) do
    if Access.owner?(ctx, member.role) and not Access.owner?(ctx, role),
      do: Access.check_not_last_owner(ctx, member),
      else: :ok
  end

  defp valid_role(ctx, organization, role) do
    if Access.valid_role?(ctx, organization, role),
      do: :ok,
      else: {:error, Errors.error(:invalid_role)}
  end

  defp not_member(ctx, organization, user) do
    if Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id),
      do: {:error, Errors.error(:already_member)},
      else: :ok
  end

  defp under_limit(ctx, organization, opts) do
    count = Store.count(ctx, :member, members_query(ctx, organization))

    if count < opts[:membership_limit],
      do: :ok,
      else: {:error, Errors.error(:membership_limit_reached)}
  end

  # A role from a string or a list of names.
  defp role_string(roles), do: roles |> AccessControl.parse_roles() |> Enum.join(",")
end
