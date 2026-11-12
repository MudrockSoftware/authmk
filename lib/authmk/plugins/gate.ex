defmodule Authmk.Plugins.Gate do
  @moduledoc """
  Authorization: may this user do this action on this resource? In the
  spirit of Laravel's Gate, from app roles, organization roles, team roles
  and roles inside teams.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          Authmk.Plugins.Admin,
          {Authmk.Plugins.Organization, teams: [enabled: true]},
          {Authmk.Plugins.Gate,
           abilities: [invoice: [:view, :update, :delete], report: [:view, :export]],
           app_roles: [support: [invoice: [:view]]],
           organization_roles: [member: [report: [:view]]],
           team_roles: [finance: [invoice: [:view, :update]], analysts: [report: [:view, :export]]],
           team_member_roles: [employee: [invoice: [:view], report: [:view]], manager: [invoice: [:view, :update]]],
           default_team_member_role: "employee"}
        ],
        ...

      Authmk.Plugins.Gate.allows?(MyApp.Auth, user, {:invoice, :update}, invoice)
      #=> true or false

  It needs `Authmk.Plugins.Admin`, for the user's `role`. Organizations and
  teams are used when `Authmk.Plugins.Organization` has them.

  ## How a check is decided

  For `allows?(auth, user, {:invoice, :update}, invoice)`:

    1. A banned user may do nothing.
    2. An app admin (`Authmk.Plugins.Admin`'s `admin_roles` or
       `admin_user_ids`) may do everything.
    3. The user's app roles grant what `app_roles` says, in every
       organization: they're for the app's own staff.
    4. When the resource belongs to an organization:
       * an admin of that organization (`organization_admin_roles`) may do
         everything there, except `app_only` abilities, and nothing in
         organizations where they're only a member;
       * other members get what their member roles grant there, and for
         each of their teams in it, what the team's role grants, narrowed
         by their own role in the team. A member without a role in the team
         gets all the team has; a team without a role grants nothing. A
         user in several teams gets what all of them give.
    5. Everything else is denied.

  The organization comes from the resource, never from the session's
  active organization, so nobody reaches another organization's data by
  switching. The resource is `nil` (the app, no organization),
  `{:organization, id}`, `{:team, id}`, an organization or team record, or
  any map or struct with an `organization_id` or `team_id` key. With a
  `team_id`, only that team's grants count, plus organization-wide ones;
  a team in another organization than the resource names grants nothing.
  A resource with neither key raises: guessing could open it up.

  Every check reads the user, their membership, their teams and their
  organization's roles from the database: a role taken away, a ban or a
  removal from a team counts from the next check.

  ## Organizations change their own access

  The code's `organization_roles`, `team_roles` and `team_member_roles` are
  defaults for every organization. Each organization may override what
  one grants, and define its own roles at those levels, within the
  abilities the code declares and never `app_only` ones. Its own roles can
  be given to its teams and team members like the code's. App admins and
  the organization's admins do this through the endpoints, and your server
  code through the functions below.

  | Method | Path | Who |
  |---|---|---|
  | GET | `/gate/abilities` | signed in: their own, with `organization_id` or `team_id` |
  | GET | `/gate/list-roles` | app or organization admin |
  | POST | `/gate/set-role` | app or organization admin |
  | POST | `/gate/delete-role` | app or organization admin |
  | POST | `/gate/set-team-role` | app or organization admin |
  | POST | `/gate/set-team-member-role` | app or organization admin |

  `list-roles` answers with `roles` and the `abilities` the organization
  may grant. `set-role` takes `organization_id`, `level` (`organization`, `team` or
  `team_member`), `role` and `permission` (`{"invoice": ["view"]}`);
  `delete-role` takes the first three, and sends an override back to the
  code's default. An organization's own role can't be deleted while a
  team or team member has it.

  ## In plugs and LiveViews

  `Authmk.Plug.RequireAbility` and `Authmk.LiveView`'s `:require_ability`
  hook let a page through only when the user has an ability.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Gate.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Store}
  alias Authmk.Plugins.{Admin, Organization}
  alias Authmk.Plugins.Gate.{Check, Handlers, Manage, Options, Rules, Scope}

  @typedoc "An ability: `{resource, action}`, as atoms or strings."
  @type ability :: {atom() | String.t(), atom() | String.t()}

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema())
    rules = Rules.new!(opts)
    default = opts[:default_team_member_role]

    if default && not Map.has_key?(Rules.level(rules, :team_member).roles, default) do
      raise ArgumentError,
            "default_team_member_role #{inspect(default)} is not one of team_member_roles"
    end

    Keyword.put(opts, :rules, rules)
  end

  @impl true
  def depends_on, do: [Admin]

  # App roles are assigned through Authmk.Plugins.Admin, which only gives
  # out roles its access control has.
  @impl true
  def check_plugins(opts, plugins) do
    {Admin, admin_opts} = List.keyfind(plugins, Admin, 0)
    admin_roles = admin_opts[:access_control].role_names()

    for {role, _grants} <- Rules.level(opts[:rules], :app).roles, role not in admin_roles do
      raise ArgumentError,
            "Gate's app role #{role} is not a role of Authmk.Plugins.Admin's access_control " <>
              "(#{inspect(admin_opts[:access_control])}); add it there too"
    end

    check_organization_options(opts, plugins)
  end

  defp check_organization_options(opts, plugins) do
    organization = List.keyfind(plugins, Organization, 0)
    teams = organization != nil and elem(organization, 1)[:teams][:enabled] == true

    team_options =
      opts[:team_roles] != [] or opts[:team_member_roles] != [] or
        opts[:default_team_member_role] != nil

    cond do
      organization == nil and opts[:organization_roles] != [] ->
        raise ArgumentError, "Gate's organization_roles need Authmk.Plugins.Organization"

      not teams and team_options ->
        raise ArgumentError,
              "Gate's team_roles, team_member_roles and default_team_member_role need " <>
                "Authmk.Plugins.Organization with teams: [enabled: true]"

      true ->
        :ok
    end
  end

  @impl true
  def schema(_opts) do
    %{
      access_role: [
        plural: "access_roles",
        fields: [
          # Without a foreign key: the Organization plugin may be off. Rows
          # go with their organization (see database_hook/4).
          organization_id: [type: :string, required: true, index: true, input: false],
          level: [type: :string, required: true, input: false],
          role: [type: :string, required: true, input: false],
          # JSON: %{resource => [action]}
          permission: [type: :text, required: true, input: false]
        ],
        indexes: [[columns: [:organization_id, :level, :role], unique: true]]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    organization_id = [organization_id: [type: :string, required: true]]

    role =
      organization_id ++
        [level: [type: :string, required: true], role: [type: :string, required: true]]

    [
      endpoint(:gate_abilities, :get, "/gate/abilities", :abilities,
        organization_id: [type: :string],
        team_id: [type: :string]
      ),
      endpoint(:gate_list_roles, :get, "/gate/list-roles", :list_roles, organization_id),
      endpoint(
        :gate_set_role,
        :post,
        "/gate/set-role",
        :set_role,
        role ++ [permission: [type: :map, required: true]]
      ),
      endpoint(:gate_delete_role, :post, "/gate/delete-role", :delete_role, role),
      endpoint(:gate_set_team_role, :post, "/gate/set-team-role", :set_team_role,
        team_id: [type: :string, required: true],
        role: [type: :string]
      ),
      endpoint(
        :gate_set_team_member_role,
        :post,
        "/gate/set-team-member-role",
        :set_team_member_role,
        team_id: [type: :string, required: true],
        user_id: [type: :string, required: true],
        role: [type: :string]
      )
    ]
  end

  defp endpoint(name, method, path, handler, params) do
    Endpoint.new(
      name: name,
      method: method,
      path: path,
      handler: {Handlers, handler},
      session: :required,
      params: params
    )
  end

  # New team members get `default_team_member_role` unless given one; an
  # organization's roles go with it.
  @impl true
  def database_hook(:before_create, :team_member, attrs, ctx) do
    case opts(ctx)[:default_team_member_role] do
      nil -> {:ok, attrs}
      default -> {:ok, put_default_role(attrs, default)}
    end
  end

  def database_hook(:after_delete, :organization, organization, ctx) do
    Store.delete_all(ctx, :access_role, organization_id: to_string(organization.id))
    :ok
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  defp put_default_role(attrs, default) do
    key = if Enum.any?(Map.keys(attrs), &is_binary/1), do: "role", else: :role
    Map.update(attrs, key, default, &(&1 || default))
  end

  @doc """
  Whether `user` may do `ability` on `resource` (see the module docs for
  resources). Raises for abilities the code doesn't declare.

      Authmk.Plugins.Gate.allows?(MyApp.Auth, user, {:report, :view})
      Authmk.Plugins.Gate.allows?(MyApp.Auth, user, {:invoice, :update}, invoice)
  """
  @spec allows?(module(), struct() | nil, ability(), term()) :: boolean()
  def allows?(auth, user, ability, resource \\ nil) do
    ctx = server_ctx(auth)
    opts = opts(ctx)
    ability = Rules.ability!(opts[:rules], ability)
    scope = Scope.of(ctx, resource)
    allowed = Rules.allows?(Check.granted(ctx, opts, user, scope), ability)

    unless allowed, do: denied(auth, user, ability, scope)
    allowed
  end

  @doc """
  Like `allows?/4`: `:ok`, or `{:error, %Authmk.Error{code: :forbidden}}`.

      with :ok <- Authmk.Plugins.Gate.authorize(MyApp.Auth, user, {:invoice, :delete}, invoice) do
        Invoices.delete(invoice)
      end
  """
  @spec authorize(module(), struct() | nil, ability(), term()) :: :ok | {:error, Error.t()}
  def authorize(auth, user, ability, resource \\ nil) do
    if allows?(auth, user, ability, resource), do: :ok, else: {:error, Error.new(:forbidden)}
  end

  @doc """
  Everything `user` may do on `resource`, as `%{"invoice" => ["update",
  "view"]}`: for showing only the menus and buttons they can use.
  """
  @spec abilities(module(), struct() | nil, term()) :: %{String.t() => [String.t()]}
  def abilities(auth, user, resource \\ nil) do
    ctx = server_ctx(auth)
    ctx |> Check.granted(opts(ctx), user, Scope.of(ctx, resource)) |> Rules.to_lists()
  end

  @doc """
  The abilities an organization may grant its roles: every declared one but
  the `app_only` ones, as `%{"invoice" => ["update", "view"]}`. For
  building a page where organization admins edit their roles.
  """
  @spec organization_abilities(module()) :: %{String.t() => [String.t()]}
  def organization_abilities(auth) do
    auth
    |> server_ctx()
    |> opts()
    |> Keyword.fetch!(:rules)
    |> Rules.organization_wide()
    |> Rules.to_lists()
  end

  @doc """
  An organization's roles at every level: maps with `:level`, `:role`,
  `:permission` and `:source` (`"code"`, `"override"` or `"organization"`).
  """
  @spec list_roles(module(), term()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_roles(auth, organization_id) do
    with_organization(auth, organization_id, &Manage.list_roles/3)
  end

  @doc """
  Sets what `role` grants at `level` (`:organization`, `:team` or
  `:team_member`) in an organization: overrides a code role of that name,
  or creates or changes one of the organization's own. `permission` is
  `%{invoice: [:view]}`, within the declared abilities and none app-only.

      Authmk.Plugins.Gate.put_role(MyApp.Auth, org.id, :team_member, "editor", %{invoice: [:view, :update]})
  """
  @spec put_role(module(), term(), atom() | String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def put_role(auth, organization_id, level, role, permission) do
    with_organization(
      auth,
      organization_id,
      &Manage.put_role(&1, &2, &3, level, role, permission)
    )
  end

  @doc """
  Removes an organization's role: an override goes back to the code's
  default. An organization's own role can't go while a team or team member
  has it (`role_assigned`).
  """
  @spec delete_role(module(), term(), atom() | String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def delete_role(auth, organization_id, level, role) do
    with_organization(auth, organization_id, &Manage.delete_role(&1, &2, &3, level, role))
  end

  @doc """
  Gives a team a team role, from the code or its organization's own; `nil`
  takes it away. Its members inherit what it grants.
  """
  @spec set_team_role(module(), term(), String.t() | nil) :: {:ok, struct()} | {:error, Error.t()}
  def set_team_role(auth, team_id, role) do
    ctx = server_ctx(auth)

    with {:ok, team} <- Manage.fetch_team(ctx, team_id),
         do: Manage.set_team_role(ctx, opts(ctx), team, role)
  end

  @doc """
  Gives a member of a team a role in it, from the code or the
  organization's own; `nil` takes it away, and they get all the team has.
  """
  @spec set_team_member_role(module(), term(), term(), String.t() | nil) ::
          {:ok, struct()} | {:error, Error.t()}
  def set_team_member_role(auth, team_id, user_id, role) do
    ctx = server_ctx(auth)

    with {:ok, team} <- Manage.fetch_team(ctx, team_id),
         do: Manage.set_team_member_role(ctx, opts(ctx), team, user_id, role)
  end

  defp with_organization(auth, organization_id, fun) do
    ctx = server_ctx(auth)

    with {:ok, organization} <- Manage.fetch_organization(ctx, organization_id),
         do: fun.(ctx, opts(ctx), organization)
  end

  # Denials are worth watching: a spike can be a probe, or a broken role.
  # Only ids: the resource itself may hold anything.
  defp denied(auth, user, {resource, action}, scope) do
    organization_id =
      case scope do
        {:organization, id, _team_id} -> to_string(id)
        _app_or_nowhere -> nil
      end

    :telemetry.execute([:authmk, :gate, :denied], %{}, %{
      auth: auth,
      user_id: user && Map.get(user, :id),
      ability: {resource, action},
      organization_id: organization_id
    })
  end

  defp server_ctx(auth), do: Context.new(auth.config())

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
