defmodule Authmk.Plugins.Gate.Rules do
  @moduledoc false
  # The rules declared in code, built once at startup: the abilities, what
  # each role grants at each level, and the abilities only app roles grant.
  # Grants are `%{"resource" => MapSet of "action"}`, as in
  # Authmk.AccessControl.

  alias Authmk.AccessControl

  @levels [:app, :organization, :team, :team_member]

  @enforce_keys [:abilities, :app_only, :levels]
  defstruct [:abilities, :app_only, :levels]

  @type grants :: %{String.t() => MapSet.t(String.t())}

  @doc "The role levels, broadest first."
  def levels, do: @levels

  @doc "Builds the rules from the plugin's options. Raises on unknown abilities."
  def new!(opts) do
    abilities = opts[:abilities]
    statements = AccessControl.new!(abilities, []).statements
    app_only = AccessControl.new!(abilities, app_only: opts[:app_only]).roles["app_only"]

    levels =
      Map.new(@levels, fn level ->
        roles = opts[:"#{level}_roles"]
        {level, AccessControl.new!(abilities, roles)}
      end)

    rules = %__MODULE__{abilities: statements, app_only: app_only, levels: levels}

    for level <- @levels -- [:app], {role, grants} <- levels[level].roles do
      if overlaps?(grants, app_only) do
        raise ArgumentError,
              "#{level} role #{role} grants an app-only ability; only app roles may"
      end
    end

    rules
  end

  @doc "The access control of `level`: the abilities and the roles code declares."
  def level(%__MODULE__{levels: levels}, level), do: Map.fetch!(levels, level)

  @doc "Every ability."
  def everything(%__MODULE__{abilities: abilities}), do: abilities

  @doc "Every ability an organization may grant: all but the app-only ones."
  def organization_wide(%__MODULE__{abilities: abilities, app_only: app_only}),
    do: subtract(abilities, app_only)

  @doc """
  `{resource, action}` as strings. Raises for abilities the code doesn't
  declare: asking for one is a bug, and nothing grants it.
  """
  def ability!(%__MODULE__{abilities: abilities}, {resource, action}) do
    ability = {to_string(resource), to_string(action)}

    if allows?(abilities, ability),
      do: ability,
      else: raise(ArgumentError, "unknown ability #{inspect({resource, action})}")
  end

  def ability!(_rules, other),
    do: raise(ArgumentError, "abilities are {resource, action} tuples, got: #{inspect(other)}")

  @doc """
  Whether an organization may grant `permission` (`%{resource => [action]}`
  from a request): declared abilities only, none app-only.
  """
  def grantable?(%__MODULE__{abilities: abilities, app_only: app_only}, permission) do
    ac = %AccessControl{statements: abilities, roles: %{}}

    with true <- shaped?(permission),
         {:ok, ac} <- AccessControl.put_role(ac, "new", permission) do
      not overlaps?(ac.roles["new"], app_only)
    else
      _invalid -> false
    end
  end

  # `%{resource => [action]}`, with names as strings or atoms.
  defp shaped?(permission) when is_map(permission) do
    Enum.all?(permission, fn {resource, actions} ->
      name?(resource) and is_list(actions) and Enum.all?(actions, &name?/1)
    end)
  end

  defp shaped?(_permission), do: false

  defp name?(name), do: is_binary(name) or (is_atom(name) and not is_nil(name))

  @doc """
  What `permission` (`%{resource => [action]}`, as stored) grants of what
  an organization may grant; anything else in it is dropped.
  """
  def only_grantable(%__MODULE__{} = rules, permission) do
    if shaped?(permission) do
      wanted =
        Map.new(permission, fn {resource, actions} ->
          {to_string(resource), MapSet.new(actions, &to_string/1)}
        end)

      intersect(wanted, organization_wide(rules))
    else
      %{}
    end
  end

  @doc "Whether `grants` include `{resource, action}`."
  def allows?(grants, {resource, action}) do
    case grants do
      %{^resource => actions} -> MapSet.member?(actions, action)
      _none -> false
    end
  end

  @doc "Grants as `%{resource => [action]}`, sorted: for JSON and for people."
  def to_lists(grants),
    do: Map.new(grants, fn {resource, actions} -> {resource, Enum.sort(actions)} end)

  @doc "Everything in either."
  def union(a, b), do: Map.merge(a, b, fn _resource, x, y -> MapSet.union(x, y) end)

  @doc "Only what both have."
  def intersect(a, b) do
    for {resource, actions} <- a,
        both = MapSet.intersection(actions, Map.get(b, resource, MapSet.new())),
        MapSet.size(both) > 0,
        into: %{},
        do: {resource, both}
  end

  defp subtract(a, b) do
    for {resource, actions} <- a,
        left = MapSet.difference(actions, Map.get(b, resource, MapSet.new())),
        MapSet.size(left) > 0,
        into: %{},
        do: {resource, left}
  end

  defp overlaps?(grants, other), do: intersect(grants, other) != %{}
end
