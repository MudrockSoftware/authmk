defmodule Authmk.AccessControl do
  @moduledoc """
  Roles and permissions, shared by the admin, organization and API key
  plugins.

  Statements list the resources and the actions on them; roles grant some of
  those actions:

      defmodule MyApp.Permissions do
        use Authmk.AccessControl,
          statements: [
            project: [:create, :update, :delete],
            billing: [:read, :update]
          ],
          roles: [
            owner: [project: [:create, :update, :delete], billing: [:read, :update]],
            member: [project: [:create, :update]],
            viewer: []
          ]
      end

      MyApp.Permissions.has_permission?("member", %{project: [:create]})
      #=> true
      MyApp.Permissions.has_permission?(["viewer", "member"], %{billing: [:read]})
      #=> false

  Checks are plain functions of the role names: no database call, so they
  work anywhere, even offline. Roles that don't exist grant nothing, and a
  role naming an action that no statement has fails at compile time.

  Users and members store roles as a comma-separated string (`"admin,member"`),
  which `has_permission?/3` takes as is. Resources and actions may be atoms or
  strings; requests carry strings.
  """

  @enforce_keys [:statements, :roles]
  defstruct [:statements, :roles]

  @type t :: %__MODULE__{
          statements: %{String.t() => MapSet.t(String.t())},
          roles: %{String.t() => %{String.t() => MapSet.t(String.t())}}
        }

  @typedoc "Resources and their actions, like `%{project: [:create]}` or `[project: [\"create\"]]`."
  @type permissions :: map() | keyword()

  @typedoc "Role names: a list, or a comma-separated string."
  @type roles :: [String.t() | atom()] | String.t() | atom() | nil

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @authmk_access_control Authmk.AccessControl.new!(
                               Keyword.fetch!(opts, :statements),
                               Keyword.fetch!(opts, :roles)
                             )

      @doc "The access control definition. See `Authmk.AccessControl`."
      def access_control, do: @authmk_access_control

      @doc "Whether `roles` grant every action in `permissions`. See `Authmk.AccessControl.has_permission?/4`."
      def has_permission?(roles, permissions, connector \\ :and),
        do:
          Authmk.AccessControl.has_permission?(
            @authmk_access_control,
            roles,
            permissions,
            connector
          )

      @doc "The role names."
      def role_names, do: Authmk.AccessControl.role_names(@authmk_access_control)
    end
  end

  @doc """
  Builds an access control definition. Raises when a role names a resource
  or action that no statement has.
  """
  @spec new!(permissions(), %{(atom() | String.t()) => permissions()} | keyword()) :: t()
  def new!(statements, roles) do
    statements = normalize(statements)

    roles =
      Map.new(roles, fn {name, grants} ->
        grants = normalize(grants)
        check_grants!(name, grants, statements)
        {to_string(name), grants}
      end)

    %__MODULE__{statements: statements, roles: roles}
  end

  @doc """
  Whether `roles` grant `permissions`. With `:and` (the default) every
  action asked for must be granted, by any of the roles; with `:or`, one is
  enough. Asking for nothing is `false`.
  """
  @spec has_permission?(t(), roles(), permissions(), :and | :or) :: boolean()
  def has_permission?(%__MODULE__{} = ac, roles, permissions, connector \\ :and) do
    granted = granted(ac, roles)

    wanted =
      for {resource, actions} <- normalize(permissions), action <- actions, do: {resource, action}

    case {wanted, connector} do
      {[], _connector} -> false
      {wanted, :and} -> Enum.all?(wanted, &granted?(granted, &1))
      {wanted, :or} -> Enum.any?(wanted, &granted?(granted, &1))
    end
  end

  @doc """
  Adds a role at runtime, like an organization's own role. Fails when it
  grants anything no statement has.
  """
  @spec put_role(t(), String.t() | atom(), permissions()) :: {:ok, t()} | {:error, String.t()}
  def put_role(%__MODULE__{} = ac, name, grants) do
    grants = normalize(grants)
    check_grants!(name, grants, ac.statements)
    {:ok, %{ac | roles: Map.put(ac.roles, to_string(name), grants)}}
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  @doc "What a role grants, as `%{resource => [action]}`, or `nil` for unknown roles."
  @spec role(t(), String.t() | atom()) :: %{String.t() => [String.t()]} | nil
  def role(%__MODULE__{roles: roles}, name) do
    case Map.fetch(roles, to_string(name)) do
      {:ok, grants} ->
        Map.new(grants, fn {resource, actions} -> {resource, Enum.sort(actions)} end)

      :error ->
        nil
    end
  end

  @doc "Everything `roles` grant together: `%{resource => MapSet of actions}`."
  @spec granted(t(), roles()) :: %{String.t() => MapSet.t(String.t())}
  def granted(%__MODULE__{roles: defined}, roles) do
    roles
    |> parse_roles()
    |> Enum.map(&Map.get(defined, &1, %{}))
    |> Enum.reduce(%{}, fn grants, acc ->
      Map.merge(acc, grants, fn _resource, a, b -> MapSet.union(a, b) end)
    end)
  end

  @doc "The defined role names."
  @spec role_names(t()) :: [String.t()]
  def role_names(%__MODULE__{roles: roles}), do: roles |> Map.keys() |> Enum.sort()

  @doc ~s(Role names from a list or a comma-separated string: `"admin, member"` gives `["admin", "member"]`.)
  @spec parse_roles(roles()) :: [String.t()]
  def parse_roles(nil), do: []
  def parse_roles(roles) when is_list(roles), do: Enum.flat_map(roles, &parse_roles/1)
  def parse_roles(role) when is_atom(role), do: [Atom.to_string(role)]

  def parse_roles(roles) when is_binary(roles) do
    roles |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @doc "Whether every role in `roles` is defined."
  @spec valid_roles?(t(), roles()) :: boolean()
  def valid_roles?(%__MODULE__{roles: defined}, roles) do
    case parse_roles(roles) do
      [] -> false
      names -> Enum.all?(names, &Map.has_key?(defined, &1))
    end
  end

  defp granted?(granted, {resource, action}) do
    case granted do
      %{^resource => actions} -> MapSet.member?(actions, action)
      _none -> false
    end
  end

  # %{"resource" => MapSet of "action"}, from atoms or strings, maps or keywords.
  defp normalize(permissions) when is_map(permissions) or is_list(permissions) do
    Map.new(permissions, fn {resource, actions} ->
      {to_string(resource), MapSet.new(List.wrap(actions), &to_string/1)}
    end)
  end

  defp check_grants!(role, grants, statements) do
    for {resource, actions} <- grants do
      known =
        Map.get(statements, resource) ||
          raise ArgumentError, "role #{role} grants unknown resource #{resource}"

      unknown = MapSet.difference(actions, known)

      if MapSet.size(unknown) > 0 do
        raise ArgumentError,
              "role #{role} grants unknown #{resource} actions: #{Enum.join(Enum.sort(unknown), ", ")}"
      end
    end

    :ok
  end
end
