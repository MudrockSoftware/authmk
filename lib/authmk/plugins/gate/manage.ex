defmodule Authmk.Plugins.Gate.Manage do
  @moduledoc false
  # Changing an organization's access: its roles, and the roles of its teams
  # and team members. Used by the server functions in Authmk.Plugins.Gate
  # and, after checking who asks, by its endpoints. `opts` are the
  # plugin's, passed in so this module doesn't depend on the plugin.

  alias Authmk.{Error, Store}
  alias Authmk.Plugins.Gate.{Errors, Roles}
  alias Authmk.Plugins.Organization

  def list_roles(ctx, opts, organization) do
    {:ok, Roles.list(ctx, opts[:rules], organization.id)}
  end

  def put_role(ctx, opts, organization, level, role, permission) do
    limit = opts[:maximum_roles_per_organization]

    with {:ok, level} <- Roles.level(ctx, level),
         do: Roles.put(ctx, opts[:rules], limit, organization.id, level, role, permission)
  end

  def delete_role(ctx, opts, organization, level, role) do
    with {:ok, level} <- Roles.level(ctx, level),
         do: Roles.delete(ctx, opts[:rules], organization.id, level, role)
  end

  @doc "Gives a team a role (`nil` takes it away): one its organization has."
  def set_team_role(ctx, opts, team, role) do
    with :ok <- defined(ctx, opts, team.organization_id, :team, role),
         do: Store.update(ctx, :team, team, %{role: role})
  end

  @doc "Gives a team member a role in the team (`nil` takes it away)."
  def set_team_member_role(ctx, opts, team, user_id, role) do
    with {:ok, team_member} <- fetch_team_member(ctx, team, user_id),
         :ok <- defined(ctx, opts, team.organization_id, :team_member, role),
         do: Store.update(ctx, :team_member, team_member, %{role: role})
  end

  @doc "An organization by id, when the Organization plugin is on."
  def fetch_organization(ctx, id) do
    with :ok <- organizations_enabled(ctx) do
      case get(ctx, :organization, id) do
        nil -> {:error, Errors.error(:organization_not_found)}
        organization -> {:ok, organization}
      end
    end
  end

  @doc "A team by id, when teams are on."
  def fetch_team(ctx, id) do
    with :ok <- teams_enabled(ctx) do
      case get(ctx, :team, id) do
        nil -> {:error, Errors.error(:team_not_found)}
        team -> {:ok, team}
      end
    end
  end

  defp fetch_team_member(ctx, team, user_id) do
    case get(ctx, :team_member, team_id: team.id, user_id: user_id) do
      nil -> {:error, Errors.error(:member_not_found)}
      team_member -> {:ok, team_member}
    end
  end

  defp defined(_ctx, _opts, _organization_id, _level, nil), do: :ok

  defp defined(ctx, opts, organization_id, level, role) do
    if Roles.defined?(ctx, opts[:rules], organization_id, level, role),
      do: :ok,
      else: {:error, Errors.error(:invalid_role)}
  end

  defp get(_ctx, _model, nil), do: nil
  defp get(ctx, model, clauses) when is_list(clauses), do: safe_get(ctx, model, clauses)
  defp get(ctx, model, id), do: safe_get(ctx, model, id: id)

  # Ids that aren't valid for the database find nothing.
  defp safe_get(ctx, model, clauses) do
    if Enum.any?(clauses, fn {_field, value} -> is_nil(value) end),
      do: nil,
      else: Store.get_by(ctx, model, clauses)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp organizations_enabled(ctx) do
    if List.keymember?(ctx.config.plugins, Organization, 0),
      do: :ok,
      else: {:error, Error.new(:feature_disabled)}
  end

  defp teams_enabled(ctx) do
    if Map.has_key?(ctx.config.schema.models, :team),
      do: :ok,
      else: {:error, Error.new(:feature_disabled)}
  end
end
