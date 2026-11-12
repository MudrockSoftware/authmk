defmodule Authmk.Plugins.Gate.Handlers do
  @moduledoc false
  # The plugin's endpoints. Changing an organization's access takes an app
  # admin or an admin of that organization.

  alias Authmk.{Context, Error, Serializer, Store}
  alias Authmk.Plugins.Gate.{Check, Manage, Rules, Scope}

  def abilities(%Context{params: params, user: user} = ctx) do
    resource =
      cond do
        params.team_id -> {:team, params.team_id}
        params.organization_id -> {:organization, params.organization_id}
        true -> nil
      end

    grants = Check.granted(ctx, opts(ctx), user, Scope.of(ctx, resource))
    {:ok, %{abilities: Rules.to_lists(grants)}, ctx}
  end

  def list_roles(%Context{params: params} = ctx) do
    with {:ok, organization} <- managed_organization(ctx, params.organization_id),
         {:ok, roles} <- Manage.list_roles(ctx, opts(ctx), organization) do
      abilities = opts(ctx)[:rules] |> Rules.organization_wide() |> Rules.to_lists()
      {:ok, %{roles: roles, abilities: abilities}, ctx}
    end
  end

  def set_role(%Context{params: params} = ctx) do
    with {:ok, organization} <- managed_organization(ctx, params.organization_id),
         {:ok, role} <-
           Manage.put_role(
             ctx,
             opts(ctx),
             organization,
             params.level,
             params.role,
             params.permission
           ) do
      {:ok, role, ctx}
    end
  end

  def delete_role(%Context{params: params} = ctx) do
    with {:ok, organization} <- managed_organization(ctx, params.organization_id),
         {:ok, body} <-
           Manage.delete_role(ctx, opts(ctx), organization, params.level, params.role) do
      {:ok, body, ctx}
    end
  end

  def set_team_role(%Context{params: params} = ctx) do
    with {:ok, team} <- Manage.fetch_team(ctx, params.team_id),
         {:ok, _organization} <- managed_organization(ctx, team.organization_id),
         {:ok, team} <- Manage.set_team_role(ctx, opts(ctx), team, params.role) do
      {:ok, Serializer.record(ctx, :team, team), ctx}
    end
  end

  def set_team_member_role(%Context{params: params} = ctx) do
    with {:ok, team} <- Manage.fetch_team(ctx, params.team_id),
         {:ok, _organization} <- managed_organization(ctx, team.organization_id),
         {:ok, team_member} <-
           Manage.set_team_member_role(ctx, opts(ctx), team, params.user_id, params.role) do
      {:ok, Serializer.record(ctx, :team_member, team_member), ctx}
    end
  end

  # The organization, when the signed-in user may change its access. Their
  # role is read again: the session's copy may come from the cookie cache.
  defp managed_organization(%Context{user: user} = ctx, organization_id) do
    with {:ok, organization} <- Manage.fetch_organization(ctx, organization_id) do
      if manager?(ctx, Store.get_by(ctx, :user, id: user.id), organization),
        do: {:ok, organization},
        else: {:error, Error.new(:forbidden)}
    end
  end

  defp manager?(_ctx, nil, _organization), do: false

  defp manager?(ctx, user, organization) do
    member = Check.membership(ctx, organization.id, user)

    Check.app_admin?(ctx, user) or
      (member != nil and Check.organization_admin?(opts(ctx), member))
  end

  # The plugin's options, found through the endpoint: this module doesn't
  # depend on the plugin, which depends on it.
  defp opts(%Context{endpoint: %{plugin: plugin}} = ctx), do: Context.plugin_opts(ctx, plugin)
end
