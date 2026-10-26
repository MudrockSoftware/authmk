defmodule Authmk.Plugins.ServiceAccount do
  @moduledoc """
  Service accounts: identities for programs, not people. They belong to a
  user or an organization, have no email, no password and no way to sign in
  interactively, and authenticate with API keys.

      use Authmk,
        plugins: [
          Authmk.Plugins.APIKey,
          {Authmk.Plugins.ServiceAccount, access_control: MyApp.Permissions}
        ],
        ...

  A request carrying a service account's key (`x-api-key`) is authenticated
  as that service account: `Authmk.Plug.FetchSession` assigns it as
  `current_principal` (and `current_user` stays `nil`). Let it through your
  routes with `plug Authmk.Plug.RequireAuthenticated, allow_principals: true`,
  and check what it may do with `has_permission?/3`.

  A service account is refused when it's disabled, expired, or the request
  comes from outside its `allowed_ips` (addresses or CIDR ranges). Keys
  rotate without downtime: create the new key, switch over, revoke the old.

  Roles: an organization's service accounts take the organization's roles;
  a user's take roles from `access_control`. Either way a service account
  may only get what its creator may do themselves.

  | Method | Path | Permission |
  |---|---|---|
  | POST | `/service-account/create` | owner, or `service_account: create` in the organization |
  | GET | `/service-account/list` | |
  | GET | `/service-account/get` | `read` |
  | POST | `/service-account/update` | `update` (also disables and enables) |
  | POST | `/service-account/delete` | `delete` |
  | POST | `/service-account/create-key` | `update` |
  | GET | `/service-account/list-keys` | `read` |
  | POST | `/service-account/revoke-key` | `update` |

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.ServiceAccount.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{AccessControl, Context, Endpoint, Error, Request, Serializer, Store}
  alias Authmk.Plugins.APIKey
  alias Authmk.Plugins.Organization.Access
  alias Authmk.Plugins.ServiceAccount.{IPAllowList, Options}

  # last_used_at is written at most this often, in seconds.
  @touch_every 60

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def depends_on, do: [APIKey]

  @impl true
  def schema(_opts) do
    %{
      service_account: [
        plural: "service_accounts",
        fields: [
          name: [type: :string, required: true],
          description: [type: :text],
          user_id: [references: :user, on_delete: :delete_all, index: true, input: false],
          # Without a foreign key: the organization plugin may not be on.
          organization_id: [type: :string, index: true, input: false],
          role: [type: :string, input: false],
          disabled: [type: :boolean, required: true, default: false, input: false],
          expires_at: [type: :datetime, input: false],
          # Comma-separated addresses and CIDR ranges. Empty: anywhere.
          allowed_ips: [type: :text, input: false],
          last_used_at: [type: :datetime, input: false]
        ]
      ],
      api_key: [
        fields: [
          service_account_id: [
            references: :service_account,
            on_delete: :delete_all,
            index: true,
            input: false
          ]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    id = [id: [type: :string, required: true]]

    settings = [
      description: [type: :string],
      role: [type: :string],
      allowed_ips: [type: {:array, :string}],
      expires_in: [type: :integer]
    ]

    [
      endpoint(
        :create_service_account,
        :post,
        "/service-account/create",
        :create,
        [name: [type: :string, required: true], organization_id: [type: :string]] ++ settings
      ),
      endpoint(:list_service_accounts, :get, "/service-account/list", :list,
        organization_id: [type: :string]
      ),
      endpoint(:get_service_account, :get, "/service-account/get", :get, id),
      endpoint(
        :update_service_account,
        :post,
        "/service-account/update",
        :update,
        id ++ [name: [type: :string], disabled: [type: :boolean]] ++ settings
      ),
      endpoint(:delete_service_account, :post, "/service-account/delete", :delete, id),
      endpoint(
        :create_service_account_key,
        :post,
        "/service-account/create-key",
        :create_key,
        id ++ [name: [type: :string], expires_in: [type: :integer], config_id: [type: :string]]
      ),
      endpoint(:list_service_account_keys, :get, "/service-account/list-keys", :list_keys, id),
      endpoint(
        :revoke_service_account_key,
        :post,
        "/service-account/revoke-key",
        :revoke_key,
        id ++ [key_id: [type: :string, required: true]]
      )
    ]
  end

  # A service account's key in the header authenticates it, not a user.
  @impl true
  def authenticate_request(%Context{conn: conn, config: config} = ctx) do
    with key when is_binary(key) <- header_key(conn, opts(ctx)[:headers]),
         %{service_account_id: id} when not is_nil(id) <- APIKey.lookup(ctx, key) do
      with {:ok, _api_key} <- APIKey.verify(config.auth, key),
           {:ok, service_account} <- fetch(ctx, id),
           :ok <- usable(ctx, service_account) do
        {:principal, touch(ctx, service_account)}
      end
    else
      _not_a_service_account_key -> :none
    end
  end

  # Without a foreign key to organizations, their service accounts go here.
  @impl true
  def database_hook(:after_delete, :organization, organization, ctx) do
    _count = Store.delete_all(ctx, :service_account, organization_id: to_string(organization.id))
    :ok
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @doc """
  Whether `service_account` may do `permissions`, by its role: the
  organization's roles for an organization's service account, otherwise
  `access_control`'s.
  """
  @spec has_permission?(module(), struct(), AccessControl.permissions()) :: boolean()
  def has_permission?(auth, service_account, permissions) do
    ctx = Context.new(auth.config())

    case access_control(ctx, service_account) do
      {:ok, ac} -> AccessControl.has_permission?(ac, service_account.role, permissions)
      :error -> false
    end
  end

  @doc false
  def create(%Context{params: params, user: user} = ctx) do
    with {:ok, owner} <- owner(ctx, params.organization_id, :create),
         :ok <- valid_ips(params.allowed_ips),
         :ok <- grantable(ctx, owner, params.role),
         attrs = Map.merge(owner_attrs(owner, user), settings(params)),
         {:ok, service_account} <-
           Store.insert(ctx, :service_account, Map.put(attrs, :name, params.name)) do
      {:ok, serialize(ctx, service_account), ctx}
    end
  end

  @doc false
  def list(%Context{params: params, user: user} = ctx) do
    with {:ok, owner} <- owner(ctx, params.organization_id, :read) do
      clauses = if owner == :user, do: [user_id: user.id], else: [organization_id: elem(owner, 1)]
      {:ok, ctx |> Store.all(:service_account, clauses) |> Enum.map(&serialize(ctx, &1)), ctx}
    end
  end

  @doc false
  def get(%Context{params: params} = ctx) do
    with {:ok, service_account, _owner} <- own(ctx, params.id, :read),
         do: {:ok, serialize(ctx, service_account), ctx}
  end

  @doc false
  def update(%Context{params: params} = ctx) do
    with {:ok, service_account, owner} <- own(ctx, params.id, :update),
         :ok <- valid_ips(params.allowed_ips),
         :ok <- if(params.role, do: grantable(ctx, owner, params.role), else: :ok),
         attrs = Map.merge(settings(params), Map.take(params, [:name, :disabled])),
         attrs = Map.reject(attrs, fn {_field, value} -> is_nil(value) end),
         {:ok, service_account} <- Store.update(ctx, :service_account, service_account, attrs) do
      {:ok, serialize(ctx, service_account), ctx}
    end
  end

  @doc false
  def delete(%Context{params: params} = ctx) do
    with {:ok, service_account, _owner} <- own(ctx, params.id, :delete),
         {:ok, _deleted} <- Store.delete(ctx, :service_account, service_account) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  # A new key next to the old ones, so callers switch over before the old is revoked.
  def create_key(%Context{params: params, config: config} = ctx) do
    attrs = %{
      service_account_id: params.id,
      name: params.name,
      expires_in: params.expires_in,
      config_id: params.config_id,
      client: true
    }

    with {:ok, _service_account, _owner} <- own(ctx, params.id, :update),
         {:ok, created} <-
           APIKey.create(config.auth, Map.reject(attrs, fn {_k, v} -> is_nil(v) end)) do
      {:ok, Map.put(created.api_key, :key, created.key), ctx}
    end
  end

  @doc false
  def list_keys(%Context{params: params, config: config} = ctx) do
    with {:ok, service_account, _owner} <- own(ctx, params.id, :read) do
      {:ok, APIKey.list_for(config.auth, :service_account_id, service_account.id), ctx}
    end
  end

  @doc false
  def revoke_key(%Context{params: params, config: config} = ctx) do
    with {:ok, service_account, _owner} <- own(ctx, params.id, :update),
         true <-
           Enum.any?(
             APIKey.list_for(config.auth, :service_account_id, service_account.id),
             &(to_string(&1.id) == params.key_id)
           ),
         :ok <- APIKey.delete(config.auth, params.key_id) do
      {:ok, %{success: true}, ctx}
    else
      false -> {:error, error(:key_not_found)}
      error -> error
    end
  end

  defp usable(ctx, service_account) do
    cond do
      service_account.disabled -> {:error, error(:service_account_disabled)}
      expired?(service_account) -> {:error, error(:service_account_expired)}
      not ip_allowed?(ctx, service_account) -> {:error, error(:ip_not_allowed)}
      true -> :ok
    end
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}),
    do: not DateTime.after?(expires_at, DateTime.utc_now())

  defp ip_allowed?(_ctx, %{allowed_ips: blank}) when blank in [nil, ""], do: true

  defp ip_allowed?(ctx, %{allowed_ips: ips}),
    do: IPAllowList.allowed?(Request.client_ip(ctx), String.split(ips, ","))

  defp touch(ctx, service_account) do
    now = DateTime.utc_now()
    last = service_account.last_used_at

    if is_nil(last) or DateTime.diff(now, last) >= @touch_every do
      case Store.update(ctx, :service_account, service_account, %{last_used_at: now}) do
        {:ok, touched} -> touched
        {:error, _error} -> service_account
      end
    else
      service_account
    end
  end

  # :user for the signed-in user's own, {:organization, id} for an organization's.
  defp owner(_ctx, nil, _action), do: {:ok, :user}

  defp owner(%Context{config: config} = ctx, organization_id, action) do
    if List.keymember?(config.plugins, Authmk.Plugins.Organization, 0) do
      with {:ok, organization, member} <-
             Access.authorize(org_ctx(ctx), organization_id, service_account: [action]) do
        {:ok, {:organization, to_string(organization.id), member}}
      end
    else
      {:error, Error.new(:feature_disabled)}
    end
  end

  defp own(%Context{user: user} = ctx, id, action) do
    with {:ok, service_account} <- fetch(ctx, id),
         {:ok, owner} <- owner(ctx, service_account.organization_id, action),
         true <- owner != :user or service_account.user_id == user.id do
      {:ok, service_account, owner}
    else
      false -> {:error, error(:service_account_not_found)}
      error -> error
    end
  end

  defp owner_attrs(:user, user), do: %{user_id: user.id}

  # An organization's service account outlives whoever created it.
  defp owner_attrs({:organization, id, _member}, _user), do: %{organization_id: id}

  # A role, only if the creator may do everything it grants.
  defp grantable(_ctx, _owner, nil), do: :ok

  defp grantable(%Context{user: user} = ctx, owner, role) do
    with {:ok, ac} <- owner_access_control(ctx, owner),
         true <- AccessControl.valid_roles?(ac, role) do
      if covers?(
           AccessControl.granted(ac, creator_roles(owner, user)),
           AccessControl.granted(ac, role)
         ),
         do: :ok,
         else: {:error, Error.new(:forbidden)}
    else
      _invalid -> {:error, error(:invalid_role)}
    end
  end

  # Whether `granted` has every action in `wanted`.
  defp covers?(granted, wanted) do
    Enum.all?(wanted, fn {resource, actions} ->
      MapSet.subset?(actions, Map.get(granted, resource, MapSet.new()))
    end)
  end

  defp creator_roles({:organization, _id, member}, _user), do: member.role
  defp creator_roles(:user, user), do: Map.get(user, :role)

  defp owner_access_control(ctx, {:organization, id, _member}) do
    with {:ok, organization} <- Access.fetch_organization(org_ctx(ctx), id) do
      {:ok, Access.access_control(org_ctx(ctx), organization)}
    end
  end

  defp owner_access_control(ctx, :user) do
    case opts(ctx)[:access_control] do
      nil -> :error
      module -> {:ok, module.access_control()}
    end
  end

  defp access_control(ctx, %{organization_id: id}) when not is_nil(id),
    do: owner_access_control(ctx, {:organization, id, nil})

  defp access_control(ctx, _service_account), do: owner_access_control(ctx, :user)

  defp settings(params) do
    %{
      description: params.description,
      role: params.role,
      allowed_ips: params.allowed_ips && Enum.join(params.allowed_ips, ","),
      expires_at: params.expires_in && DateTime.add(DateTime.utc_now(), params.expires_in)
    }
  end

  defp valid_ips(nil), do: :ok

  defp valid_ips(ips),
    do: if(IPAllowList.valid?(ips), do: :ok, else: {:error, error(:invalid_allowed_ips)})

  defp fetch(ctx, id) do
    case Store.get_by(ctx, :service_account, id: id) do
      nil -> {:error, error(:service_account_not_found)}
      service_account -> {:ok, service_account}
    end
  rescue
    Ecto.Query.CastError -> {:error, error(:service_account_not_found)}
  end

  defp header_key(conn, headers) do
    Enum.find_value(headers, fn header ->
      case Plug.Conn.get_req_header(conn, header) do
        [key | _] when key != "" -> key
        _none -> nil
      end
    end)
  end

  defp org_ctx(ctx),
    do: Context.put_private(ctx, :organization_plugin, Authmk.Plugins.Organization)

  defp serialize(ctx, service_account) do
    body = Serializer.record(ctx, :service_account, service_account)
    ips = service_account.allowed_ips
    Map.put(body, :allowed_ips, if(ips in [nil, ""], do: [], else: String.split(ips, ",")))
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  @errors %{
    service_account_not_found: {404, "Service account not found"},
    service_account_disabled: {401, "This service account is disabled"},
    service_account_expired: {401, "This service account has expired"},
    ip_not_allowed: {403, "This service account may not be used from here"},
    invalid_allowed_ips: {422, "Allowed IPs must be addresses or CIDR ranges"},
    invalid_role: {422, "Unknown role"},
    key_not_found: {404, "API key not found"}
  }

  defp error(code) do
    {status, message} = Map.fetch!(@errors, code)
    Error.custom(code, status, message)
  end

  defp endpoint(name, method, path, function, params) do
    Endpoint.new(
      name: name,
      method: method,
      path: path,
      handler: {__MODULE__, function},
      session: :required,
      params: params
    )
  end
end
