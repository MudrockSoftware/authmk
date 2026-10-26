defmodule Authmk.Plugins.Organization.Roles do
  @moduledoc false
  # Dynamic access control: an organization's own roles, created and
  # changed at runtime. Only with `dynamic_access_control: [enabled: true]`.
  # A role may only grant what the statements have, and what the member
  # creating it may do themselves.

  alias Authmk.{AccessControl, Context, Store}
  alias Authmk.Plugins.Organization.{Access, Config, Errors}

  def create(%Context{params: params} = ctx) do
    opts = Config.opts(ctx)[:dynamic_access_control]

    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, member} <- Access.authorize(ctx, id, ac: [:create]),
         :ok <- new_name(ctx, organization, params.role),
         :ok <- under_limit(ctx, organization, opts[:maximum_roles_per_organization]),
         :ok <- grantable(ctx, organization, member, params.permission),
         {:ok, role} <-
           Store.insert(ctx, :organization_role, %{
             organization_id: organization.id,
             role: params.role,
             permission: JSON.encode!(params.permission)
           }) do
      {:ok, body(role), ctx}
    end
  end

  def update(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, member} <- Access.authorize(ctx, id, ac: [:update]),
         {:ok, role} <- fetch(ctx, organization, params.role),
         :ok <- grantable(ctx, organization, member, params.permission),
         {:ok, role} <-
           Store.update(ctx, :organization_role, role, %{
             permission: JSON.encode!(params.permission)
           }) do
      {:ok, body(role), ctx}
    end
  end

  # A role members still have can't go.
  def delete(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.authorize(ctx, id, ac: [:delete]),
         {:ok, role} <- fetch(ctx, organization, params.role),
         :ok <- unused(ctx, organization, role.role),
         {:ok, _role} <- Store.delete(ctx, :organization_role, role) do
      {:ok, %{status: true}, ctx}
    end
  end

  def list(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.authorize(ctx, id, ac: [:read]) do
      roles = Store.all(ctx, :organization_role, organization_id: organization.id)
      {:ok, Enum.map(roles, &body/1), ctx}
    end
  end

  def get(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.authorize(ctx, id, ac: [:read]),
         {:ok, role} <- fetch(ctx, organization, params.role) do
      {:ok, body(role), ctx}
    end
  end

  defp body(role), do: %{id: role.id, role: role.role, permission: JSON.decode!(role.permission)}

  # Within the statements, and nothing the creator can't do themselves.
  defp grantable(ctx, organization, member, permission) do
    base = Config.opts(ctx)[:access_control].access_control()

    with {:ok, _ac} <- valid_grants(base, permission) do
      if permission == %{} or Access.allowed?(ctx, organization, member.role, permission),
        do: :ok,
        else: {:error, Authmk.Error.new(:forbidden)}
    end
  end

  defp valid_grants(base, permission) do
    case AccessControl.put_role(base, "new", permission) do
      {:ok, ac} -> {:ok, ac}
      {:error, _reason} -> {:error, Errors.error(:invalid_role)}
    end
  end

  # Built-in role names are taken too.
  defp new_name(ctx, organization, name) do
    base = Config.opts(ctx)[:access_control].access_control()

    cond do
      name in AccessControl.role_names(base) ->
        {:error, Errors.error(:role_exists)}

      Store.get_by(ctx, :organization_role, organization_id: organization.id, role: name) ->
        {:error, Errors.error(:role_exists)}

      true ->
        :ok
    end
  end

  defp under_limit(_ctx, _organization, nil), do: :ok

  defp under_limit(ctx, organization, limit) do
    count =
      length(
        Store.all(ctx, :organization_role, [organization_id: organization.id], limit: limit + 1)
      )

    if count < limit, do: :ok, else: {:error, Errors.error(:role_limit_reached)}
  end

  defp unused(ctx, organization, name) do
    members = Store.all(ctx, :member, [organization_id: organization.id], limit: 10_000)

    if Enum.any?(members, &(name in AccessControl.parse_roles(&1.role))),
      do: {:error, Errors.error(:role_in_use)},
      else: :ok
  end

  defp fetch(ctx, organization, name) do
    case Store.get_by(ctx, :organization_role, organization_id: organization.id, role: name) do
      nil -> {:error, Errors.error(:role_not_found)}
      role -> {:ok, role}
    end
  end
end
