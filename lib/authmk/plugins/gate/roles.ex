defmodule Authmk.Plugins.Gate.Roles do
  @moduledoc false
  # An organization's roles, at the organization, team and team member
  # levels: the ones code declares, which the organization may override,
  # and its own. Stored as `access_role` rows; a row named like a code role
  # overrides it, any other name is the organization's own role. Functions
  # take the organization's id as the database has it; rows keep it as a
  # string (no foreign key: the Organization plugin may be off), and
  # Authmk.Plugins.Gate deletes them with their organization.

  import Ecto.Query, only: [from: 2]

  alias Authmk.AccessControl
  alias Authmk.Plugins.Gate.{Errors, Rules}
  alias Authmk.Store

  @role_name ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  # Read every row: a row left out could bring back a code default the
  # organization had narrowed.
  @row_limit 100_000

  @doc "The levels this app has: teams only when they're enabled."
  def levels(ctx) do
    if Map.has_key?(ctx.config.schema.models, :team),
      do: [:organization, :team, :team_member],
      else: [:organization]
  end

  @doc "A level from a request, if this app has it."
  def level(ctx, level) do
    case Enum.find(levels(ctx), &(Atom.to_string(&1) == to_string(level))) do
      nil -> {:error, Errors.error(:invalid_role_level)}
      level -> {:ok, level}
    end
  end

  @doc """
  What each role grants in an organization: `%{level => %{role => grants}}`.
  An organization's rows replace code roles of the same name. A row only
  grants what an organization may still grant, should the code have
  changed since it was written.
  """
  def effective(ctx, rules, organization_id) do
    base =
      Map.new([:organization, :team, :team_member], fn level ->
        {level, Rules.level(rules, level).roles}
      end)

    for row <- rows(ctx, organization_id),
        level <- [:organization, :team, :team_member],
        row.level == Atom.to_string(level),
        reduce: base do
      acc -> put_in(acc, [level, row.role], row_grants(rules, row))
    end
  end

  @doc "Everything the roles named in `roles` (a list or comma-separated string) grant."
  def grants(roles_by_name, roles) do
    roles
    |> AccessControl.parse_roles()
    |> Enum.map(&Map.get(roles_by_name, &1, %{}))
    |> Enum.reduce(%{}, &Rules.union/2)
  end

  @doc """
  An organization's roles: `%{level:, role:, permission:, source:}`, where
  source is `"code"`, `"override"` (of a code role) or `"organization"`
  (its own).
  """
  def list(ctx, rules, organization_id) do
    rows = Map.new(rows(ctx, organization_id), &{{&1.level, &1.role}, &1})

    for level <- levels(ctx),
        role <- names(rules, level, rows),
        do: describe(rules, level, role, Map.get(rows, {Atom.to_string(level), role}))
  end

  @doc """
  Sets what `role` grants at `level` in an organization: overrides a code
  role, or creates or changes the organization's own.
  """
  def put(ctx, rules, limit, organization_id, level, role, permission) do
    with :ok <- valid_name(role),
         :ok <- grantable(rules, permission),
         {:ok, _row} <- save(ctx, limit, organization_id, level, role, normalize(permission)) do
      {:ok, describe(ctx, rules, organization_id, level, role)}
    end
  end

  defp save(ctx, limit, organization_id, level, role, permission) do
    case row(ctx, organization_id, level, role) do
      nil ->
        with :ok <- under_limit(ctx, organization_id, limit) do
          Store.insert(ctx, :access_role, %{
            organization_id: to_string(organization_id),
            level: Atom.to_string(level),
            role: role,
            permission: JSON.encode!(permission)
          })
        end

      row ->
        Store.update(ctx, :access_role, row, %{permission: JSON.encode!(permission)})
    end
  end

  @doc """
  Removes an organization's row: an override goes back to the code's
  default, and an organization's own role goes, unless a team or team
  member still has it.
  """
  def delete(ctx, rules, organization_id, level, role) do
    with {:ok, row} <- fetch_row(ctx, organization_id, level, role),
         :ok <- unassigned(ctx, rules, organization_id, level, role),
         {:ok, _row} <- Store.delete(ctx, :access_role, row) do
      {:ok, %{status: true}}
    end
  end

  @doc "Whether a team or team member in the organization may get `role` at `level`."
  def defined?(ctx, rules, organization_id, level, role) do
    is_binary(role) and
      (Map.has_key?(Rules.level(rules, level).roles, role) or
         row(ctx, organization_id, level, role) != nil)
  end

  defp describe(ctx, rules, organization_id, level, role),
    do: describe(rules, level, role, row(ctx, organization_id, level, role))

  defp describe(rules, level, role, row) do
    code = Map.get(Rules.level(rules, level).roles, role)

    {grants, source} =
      cond do
        row && code -> {row_grants(rules, row), "override"}
        row -> {row_grants(rules, row), "organization"}
        true -> {code, "code"}
      end

    %{level: level, role: role, permission: to_lists(grants), source: source}
  end

  # Code roles first, then the organization's own, by name.
  defp names(rules, level, rows) do
    code = rules |> Rules.level(level) |> Map.fetch!(:roles) |> Map.keys() |> Enum.sort()
    level = Atom.to_string(level)
    own = for {{^level, role}, _row} <- rows, role not in code, do: role
    code ++ Enum.sort(own)
  end

  defp row_grants(rules, row) do
    case JSON.decode(row.permission) do
      {:ok, permission} -> Rules.only_grantable(rules, permission)
      {:error, _reason} -> %{}
    end
  end

  defp rows(ctx, organization_id) do
    Store.all(ctx, :access_role, [organization_id: to_string(organization_id)], limit: @row_limit)
  end

  defp fetch_row(ctx, organization_id, level, role) do
    case row(ctx, organization_id, level, role) do
      nil -> {:error, Errors.error(:role_not_found)}
      row -> {:ok, row}
    end
  end

  defp row(ctx, organization_id, level, role) do
    Store.get_by(ctx, :access_role,
      organization_id: to_string(organization_id),
      level: Atom.to_string(level),
      role: role
    )
  end

  defp valid_name(role) do
    if is_binary(role) and Regex.match?(@role_name, role),
      do: :ok,
      else: {:error, Errors.error(:invalid_role_name)}
  end

  defp grantable(rules, permission) do
    if Rules.grantable?(rules, permission),
      do: :ok,
      else: {:error, Errors.error(:invalid_permission)}
  end

  defp under_limit(ctx, organization_id, limit) do
    organization_id = to_string(organization_id)

    count =
      Store.count(
        ctx,
        :access_role,
        from(r in Store.module(ctx, :access_role), where: r.organization_id == ^organization_id)
      )

    if count < limit, do: :ok, else: {:error, Errors.error(:role_limit_reached)}
  end

  # An override can always go back to the code's default. An organization
  # level role is a member role the Organization plugin owns: removing its
  # row only takes away what it granted here.
  defp unassigned(ctx, rules, organization_id, level, role) do
    cond do
      Map.has_key?(Rules.level(rules, level).roles, role) -> :ok
      level == :organization -> :ok
      assigned?(ctx, organization_id, level, role) -> {:error, Errors.error(:role_assigned)}
      true -> :ok
    end
  end

  defp assigned?(ctx, organization_id, :team, role) do
    query =
      from(t in Store.module(ctx, :team),
        where: t.organization_id == ^organization_id and t.role == ^role
      )

    Store.count(ctx, :team, query) > 0
  end

  defp assigned?(ctx, organization_id, :team_member, role) do
    query =
      from(tm in Store.module(ctx, :team_member),
        join: t in ^Store.module(ctx, :team),
        on: t.id == tm.team_id,
        where: t.organization_id == ^organization_id and tm.role == ^role
      )

    Store.count(ctx, :team_member, query) > 0
  end

  defp normalize(permission) do
    Map.new(permission, fn {resource, actions} ->
      {to_string(resource), actions |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp to_lists(grants),
    do: Map.new(grants, fn {resource, actions} -> {resource, Enum.sort(actions)} end)
end
