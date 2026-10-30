defmodule Authmk.Plugins.Organization.Access do
  @moduledoc false
  # Who may do what in an organization: membership, roles (built-in and the
  # organization's own) and the active organization.

  alias Authmk.{AccessControl, Context, Store}
  alias Authmk.Plugins.Organization.{Config, Permissions}
  alias Authmk.Plugins.Organization.Errors

  @doc "The organization a request is about: the given id, or the session's active one."
  def organization_id(%Context{session: session}, nil) do
    case session && Map.get(session, :active_organization_id) do
      nil -> {:error, Errors.error(:no_active_organization)}
      id -> {:ok, id}
    end
  end

  def organization_id(_ctx, id), do: {:ok, id}

  @doc "The organization and the signed-in user's membership in it."
  def member_of(%Context{user: user} = ctx, organization_id) do
    with {:ok, organization} <- fetch_organization(ctx, organization_id) do
      case Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id) do
        nil -> {:error, Errors.error(:not_a_member)}
        member -> {:ok, organization, member}
      end
    end
  end

  @doc "Like `member_of/2`, when the member's roles grant `permissions`."
  def authorize(ctx, organization_id, permissions) do
    with {:ok, organization, member} <- member_of(ctx, organization_id) do
      if allowed?(ctx, organization, member.role, permissions),
        do: {:ok, organization, member},
        else: {:error, Authmk.Error.new(:forbidden)}
    end
  end

  @doc "Whether `roles` grant `permissions` in `organization`."
  def allowed?(ctx, organization, roles, permissions),
    do: AccessControl.has_permission?(access_control(ctx, organization), roles, permissions)

  @doc "The built-in roles, plus the organization's own when dynamic access control is on."
  def access_control(ctx, organization) do
    opts = Config.opts(ctx)
    base = opts[:access_control].access_control()

    if opts[:dynamic_access_control][:enabled] do
      ctx
      |> Store.all(:organization_role, organization_id: organization.id)
      |> Enum.reduce(base, &put_role/2)
    else
      base
    end
  end

  # A role the statements no longer cover grants nothing.
  defp put_role(role, ac) do
    case AccessControl.put_role(ac, role.role, JSON.decode!(role.permission)) do
      {:ok, ac} -> ac
      {:error, _reason} -> ac
    end
  end

  @doc "Whether every role in `roles` exists for `organization`."
  def valid_role?(ctx, organization, roles),
    do: AccessControl.valid_roles?(access_control(ctx, organization), roles)

  @doc "Whether `roles` include the creator (owner) role."
  def owner?(ctx, roles),
    do: Config.opts(ctx)[:creator_role] in AccessControl.parse_roles(roles)

  @doc "Owner rules: only owners may give, change or take the owner role."
  def check_owner_change(ctx, actor, roles) do
    if owner?(ctx, roles) and not owner?(ctx, actor.role),
      do: {:error, Errors.error(:owner_required)},
      else: :ok
  end

  @doc """
  Fails unless `actor` holds every management action `roles` grant: nobody
  can give a role stronger than their own, or change a member stronger than
  them. Only the plugin's own resources count, and not `read`: those are
  what someone could escalate with.
  """
  def check_within_reach(ctx, organization, actor, roles) do
    access_control = access_control(ctx, organization)
    managed = Enum.map(Permissions.statements(), fn {resource, _} -> to_string(resource) end)

    grants =
      for {resource, actions} <- AccessControl.granted(access_control, roles),
          resource in managed,
          actions = actions |> MapSet.delete("read") |> MapSet.to_list(),
          actions != [],
          do: {resource, actions}

    if grants == [] or AccessControl.has_permission?(access_control, actor.role, grants),
      do: :ok,
      else: {:error, Authmk.Error.new(:forbidden)}
  end

  @doc "Fails when `member` is the organization's last owner."
  def check_not_last_owner(ctx, member) do
    if owner?(ctx, member.role) and owner_count(ctx, member.organization_id) <= 1,
      do: {:error, Errors.error(:cannot_remove_last_owner)},
      else: :ok
  end

  defp owner_count(ctx, organization_id) do
    ctx
    |> Store.all(:member, [organization_id: organization_id], limit: 10_000)
    |> Enum.count(&owner?(ctx, &1.role))
  end

  @doc "An organization by id."
  def fetch_organization(_ctx, nil), do: {:error, Errors.error(:organization_not_found)}

  def fetch_organization(ctx, id) do
    case Store.get_by(ctx, :organization, id: id) do
      nil -> {:error, Errors.error(:organization_not_found)}
      organization -> {:ok, organization}
    end
  rescue
    Ecto.Query.CastError -> {:error, Errors.error(:organization_not_found)}
  end
end
