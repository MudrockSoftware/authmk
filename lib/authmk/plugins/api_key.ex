defmodule Authmk.Plugins.APIKey do
  @moduledoc """
  API keys: for users (or organizations) to call your API.

      use Authmk,
        plugins: [{Authmk.Plugins.APIKey, configurations: [default: [prefix: "sk_"]], enable_sessions: true}],
        ...

  Keys are random, shown once at creation, and stored hashed; only their
  first characters (`start`) stay readable. Check one in your API with
  `verify/3`:

      case Authmk.Plugins.APIKey.verify(MyApp.Auth, key, %{"files" => ["read"]}) do
        {:ok, api_key} -> api_key.user_id
        {:error, error} -> error.code
      end

  Verifying checks that the key exists, is enabled, hasn't expired and has
  the permissions asked for, then counts one use: keys may have `remaining`
  uses (refilled with `refill_amount` every `refill_interval` seconds) and a
  rate limit. Counting is atomic, so concurrent requests can't go over.

  With `enable_sessions: true`, a request carrying a user's key in a header
  (`x-api-key`) is signed in as that user, in the auth router and in
  `Authmk.Plug.FetchSession`. The session is built in memory, isn't stored,
  and is never fresh. A bad key in the header is refused (401).

  | Method | Path | Session |
  |---|---|---|
  | POST | `/api-key/create` | required |
  | GET | `/api-key/get` | required |
  | POST | `/api-key/update` | required |
  | POST | `/api-key/delete` | required |
  | GET | `/api-key/list` | required |

  Clients create keys with a `name`, `expires_in`, `config_id` and
  `metadata` (with `enable_metadata`). Permissions, uses, refills and rate
  limits are for your server: set them with `create/2` and `update/3`.

  With `organization_id`, keys belong to an organization
  (`Authmk.Plugins.Organization`): managing them takes the `api_key`
  permission there.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.APIKey.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Store, Token}
  alias Authmk.Plugins.APIKey.{KeyStore, Options}
  alias Authmk.Plugins.Organization.Access

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema())
    :ok = Options.validate_configurations!(opts[:configurations])
    opts
  end

  @impl true
  def schema(_opts) do
    %{
      api_key: [
        plural: "api_keys",
        fields: [
          name: [type: :string],
          # The key's first characters, to tell keys apart.
          start: [type: :string, input: false],
          prefix: [type: :string, input: false],
          # SHA-256 of the key.
          key: [
            type: :string,
            required: true,
            unique: true,
            returned: false,
            redact: true,
            input: false
          ],
          user_id: [references: :user, on_delete: :delete_all, index: true, input: false],
          # Without a foreign key: the organization plugin may not be on.
          organization_id: [type: :string, index: true, input: false],
          config_id: [type: :string, required: true, default: "default", input: false],
          enabled: [type: :boolean, required: true, default: true, input: false],
          expires_at: [type: :datetime, input: false],
          remaining: [type: :integer, input: false],
          refill_interval: [type: :integer, input: false],
          refill_amount: [type: :integer, input: false],
          last_refill_at: [type: :datetime, input: false],
          rate_limit_enabled: [type: :boolean, required: true, default: true, input: false],
          rate_limit_time_window: [type: :integer, input: false],
          rate_limit_max: [type: :integer, input: false],
          request_count: [type: :integer, required: true, default: 0, input: false],
          request_window_started_at: [type: :datetime, input: false],
          last_request_at: [type: :datetime, input: false],
          # JSON: %{resource => [action]}
          permissions: [type: :text, input: false],
          # JSON
          metadata: [type: :text, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    key_id = [key_id: [type: :string, required: true]]

    [
      endpoint(:create_api_key, :post, "/api-key/create", :create_endpoint,
        name: [type: :string],
        expires_in: [type: :integer],
        config_id: [type: :string, default: "default"],
        metadata: [type: :map],
        organization_id: [type: :string]
      ),
      endpoint(:get_api_key, :get, "/api-key/get", :get_endpoint,
        id: [type: :string, required: true]
      ),
      endpoint(
        :update_api_key,
        :post,
        "/api-key/update",
        :update_endpoint,
        key_id ++ [name: [type: :string], enabled: [type: :boolean], metadata: [type: :map]]
      ),
      endpoint(:delete_api_key, :post, "/api-key/delete", :delete_endpoint, key_id),
      endpoint(:list_api_keys, :get, "/api-key/list", :list_endpoint,
        organization_id: [type: :string]
      )
    ]
  end

  # A user's key in a header signs the request in, when sessions are on.
  @impl true
  def authenticate_request(%Context{conn: conn} = ctx) do
    opts = opts(ctx)

    with true <- opts[:enable_sessions],
         key when is_binary(key) <- header_key(conn, opts[:headers]),
         false <- service_account_key?(ctx, key) do
      key_session(ctx, key)
    else
      # Service accounts' keys are for Authmk.Plugins.ServiceAccount.
      _no_key_or_not_ours -> :none
    end
  end

  defp service_account_key?(ctx, key) do
    case lookup(ctx, key) do
      %{service_account_id: id} when not is_nil(id) -> true
      _other -> false
    end
  end

  @doc false
  # A key's record, without checking or counting it.
  def lookup(ctx, key) when is_binary(key),
    do: KeyStore.get_by_hash(ctx, opts(ctx)[:storage], Token.hash(key))

  def lookup(_ctx, _key), do: nil

  # Without a foreign key to organizations, their keys go here.
  @impl true
  def database_hook(:after_delete, :organization, organization, ctx) do
    mode = opts(ctx)[:storage]

    for key <- KeyStore.list(ctx, mode, :organization_id, to_string(organization.id)),
        do: :ok = KeyStore.delete(ctx, mode, key)

    :ok
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @doc """
  Creates a key, from your server code. `attrs` has `:user_id` or
  `:organization_id`, and may set `:name`, `:expires_in` (seconds),
  `:config_id`, `:permissions`, `:remaining`, `:refill_interval`,
  `:refill_amount`, `:rate_limit_enabled`, `:rate_limit_time_window`,
  `:rate_limit_max` and `:metadata`. Returns the key (the only time it's
  readable) and its record.
  """
  @spec create(module(), map()) :: {:ok, %{key: String.t(), api_key: map()}} | {:error, Error.t()}
  def create(auth, attrs), do: auth |> server_context() |> create_key(Map.new(attrs))

  @doc """
  Checks a key and counts one use. `permissions` (like
  `%{"files" => ["read"]}`) must all be granted to the key.
  """
  @spec verify(module(), String.t(), map() | nil) :: {:ok, map()} | {:error, Error.t()}
  def verify(auth, key, permissions \\ nil),
    do: auth |> server_context() |> verify_key(key, permissions)

  @doc """
  Changes a key, from your server code: `:name`, `:enabled`, `:expires_at`,
  `:permissions`, `:remaining`, `:refill_interval`, `:refill_amount`, the
  rate limit fields and `:metadata`.
  """
  @spec update(module(), term(), map()) :: {:ok, map()} | {:error, Error.t()}
  def update(auth, key_id, attrs) do
    ctx = server_context(auth)
    mode = opts(ctx)[:storage]

    with {:ok, key} <- fetch(ctx, key_id),
         {:ok, key} <- KeyStore.update(ctx, mode, key, Map.new(attrs)) do
      {:ok, public(key)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _not_found} -> {:error, not_found()}
    end
  end

  @doc """
  The keys of an owner: `:user_id`, `:organization_id` or (with
  `Authmk.Plugins.ServiceAccount`) `:service_account_id`.
  """
  @spec list_for(module(), :user_id | :organization_id | :service_account_id, term()) :: [map()]
  def list_for(auth, owner, id) do
    ctx = server_context(auth)
    ctx |> KeyStore.list(opts(ctx)[:storage], owner, id) |> Enum.map(&public/1)
  end

  @doc "Deletes a key."
  @spec delete(module(), term()) :: :ok | {:error, Error.t()}
  def delete(auth, key_id) do
    ctx = server_context(auth)

    with {:ok, key} <- fetch(ctx, key_id), do: KeyStore.delete(ctx, opts(ctx)[:storage], key)
  end

  @doc "Deletes expired keys. Returns how many."
  @spec delete_expired(module()) :: non_neg_integer()
  def delete_expired(auth) do
    ctx = server_context(auth)
    KeyStore.delete_expired(ctx, opts(ctx)[:storage], DateTime.utc_now())
  end

  @doc false
  def create_endpoint(%Context{params: params, user: user} = ctx) do
    attrs = %{
      name: params.name,
      expires_in: params.expires_in,
      config_id: params.config_id,
      metadata: params.metadata,
      client: true
    }

    with {:ok, owner} <- owner(ctx, params.organization_id, user, :create),
         {:ok, created} <- create_key(ctx, Map.merge(attrs, owner)) do
      {:ok, Map.put(created.api_key, :key, created.key), ctx}
    end
  end

  @doc false
  def get_endpoint(%Context{params: params} = ctx) do
    with {:ok, key} <- own_key(ctx, params.id, :read), do: {:ok, public(key), ctx}
  end

  @doc false
  def update_endpoint(%Context{params: params} = ctx) do
    opts = opts(ctx)

    attrs =
      %{name: params.name, enabled: params.enabled, metadata: params.metadata}
      |> Map.reject(fn {_field, value} -> is_nil(value) end)

    with {:ok, key} <- own_key(ctx, params.key_id, :update),
         {:ok, config} <- configuration(opts, key.config_id),
         :ok <- metadata_allowed(attrs[:metadata], config),
         {:ok, key} <- KeyStore.update(ctx, opts[:storage], key, attrs) do
      {:ok, public(key), ctx}
    end
  end

  @doc false
  def delete_endpoint(%Context{params: params} = ctx) do
    with {:ok, key} <- own_key(ctx, params.key_id, :delete),
         :ok <- KeyStore.delete(ctx, opts(ctx)[:storage], key) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def list_endpoint(%Context{params: params, user: user} = ctx) do
    with {:ok, owner} <- owner(ctx, params.organization_id, user, :read) do
      [{field, id}] = Map.to_list(owner)
      keys = KeyStore.list(ctx, opts(ctx)[:storage], field, id)
      {:ok, Enum.map(keys, &public/1), ctx}
    end
  end

  defp create_key(ctx, attrs) do
    opts = opts(ctx)

    with {:ok, config} <- configuration(opts, attrs[:config_id] || "default"),
         :ok <- name_given(attrs[:name], config),
         :ok <- metadata_allowed(attrs[:client] && attrs[:metadata], config),
         {:ok, expires_at} <- expires_at(attrs, config) do
      key = generate(opts, config)
      record = record(attrs, config, key, expires_at)

      with {:ok, stored} <- KeyStore.insert(ctx, opts[:storage], record) do
        {:ok, %{key: key, api_key: public(stored)}}
      end
    end
  end

  defp record(attrs, config, key, expires_at) do
    rate_limit = config[:rate_limit]

    %{
      name: attrs[:name],
      start: String.slice(key, 0, config[:start_length]),
      prefix: config[:prefix],
      key: Token.hash(key),
      user_id: attrs[:user_id],
      organization_id: attrs[:organization_id] && to_string(attrs[:organization_id]),
      service_account_id: attrs[:service_account_id],
      config_id: attrs[:config_id] || "default",
      enabled: true,
      expires_at: expires_at,
      remaining: attrs[:remaining],
      refill_interval: attrs[:refill_interval],
      refill_amount: attrs[:refill_amount],
      rate_limit_enabled: Map.get(attrs, :rate_limit_enabled, rate_limit[:enabled]),
      rate_limit_time_window: attrs[:rate_limit_time_window] || rate_limit[:time_window],
      rate_limit_max: attrs[:rate_limit_max] || rate_limit[:max_requests],
      request_count: 0,
      permissions: attrs[:permissions] || config[:default_permissions],
      metadata: attrs[:metadata]
    }
  end

  defp verify_key(ctx, key, permissions) do
    opts = opts(ctx)
    now = DateTime.utc_now()

    with :ok <- custom_valid(opts[:custom_key_validator], key, ctx),
         %{} = api_key <-
           is_binary(key) && KeyStore.get_by_hash(ctx, opts[:storage], Token.hash(key)),
         :ok <- usable(api_key, now),
         :ok <- permitted(api_key, permissions),
         {:ok, api_key} <- use_key(ctx, opts[:storage], api_key, now) do
      {:ok, public(api_key)}
    else
      {:error, %Error{} = error} -> {:error, error}
      _missing -> {:error, error(:invalid_api_key)}
    end
  end

  defp use_key(ctx, mode, api_key, now) do
    case KeyStore.use(ctx, mode, api_key, now) do
      {:ok, used} -> {:ok, used}
      {:error, :usage_exceeded} -> {:error, error(:api_key_usage_exceeded)}
      {:error, :rate_limited} -> {:error, error(:api_key_rate_limited)}
      {:error, _other} -> {:error, error(:invalid_api_key)}
    end
  end

  defp usable(%{enabled: false}, _now), do: {:error, error(:api_key_disabled)}

  defp usable(%{expires_at: %DateTime{} = expires_at}, now) do
    if DateTime.after?(expires_at, now), do: :ok, else: {:error, error(:api_key_expired)}
  end

  defp usable(_key, _now), do: :ok

  defp permitted(_key, nil), do: :ok

  defp permitted(key, permissions) do
    granted = key.permissions || %{}

    wanted =
      for {resource, actions} <- permissions,
          action <- List.wrap(actions),
          do: {to_string(resource), to_string(action)}

    if wanted != [] and
         Enum.all?(wanted, fn {resource, action} -> action in Map.get(granted, resource, []) end),
       do: :ok,
       else: {:error, error(:insufficient_api_key_permissions)}
  end

  defp key_session(ctx, key) do
    with {:ok, api_key} <- verify_key(ctx, key, nil),
         user_id when not is_nil(user_id) <- api_key.user_id,
         %{} = user <- Store.get_by(ctx, :user, id: user_id) do
      {:ok, mock_session(ctx, api_key, user), user}
    else
      {:error, error} -> {:error, error}
      # Organization keys have no user to sign in as.
      _no_user -> {:error, error(:invalid_api_key)}
    end
  end

  # Built in memory: it isn't stored, and it's never fresh.
  defp mock_session(ctx, api_key, user) do
    struct(Store.module(ctx, :session), %{
      id: "api-key:#{api_key.id}",
      user_id: user.id,
      user: user,
      expires_at: api_key.expires_at || DateTime.add(DateTime.utc_now(), 3600),
      inserted_at: ~U[1970-01-01 00:00:00Z],
      updated_at: DateTime.utc_now()
    })
  end

  # Keys of the signed-in user, or of an organization they may manage keys of.
  defp owner(_ctx, nil, user, _action), do: {:ok, %{user_id: user.id}}

  defp owner(%Context{config: config} = ctx, organization_id, _user, action) do
    if List.keymember?(config.plugins, Authmk.Plugins.Organization, 0) do
      ctx = Context.put_private(ctx, :organization_plugin, Authmk.Plugins.Organization)

      with {:ok, organization, _member} <-
             Access.authorize(ctx, organization_id, api_key: [action]) do
        {:ok, %{organization_id: to_string(organization.id)}}
      end
    else
      {:error, Error.new(:feature_disabled)}
    end
  end

  defp own_key(%Context{user: user} = ctx, id, action) do
    with {:ok, key} <- fetch(ctx, id),
         {:ok, owner} <- owner(ctx, key.organization_id, user, action),
         true <- owner == %{user_id: key.user_id} or Map.has_key?(owner, :organization_id) do
      {:ok, key}
    else
      false -> {:error, not_found()}
      error -> error
    end
  end

  defp fetch(ctx, id) do
    case KeyStore.get(ctx, opts(ctx)[:storage], id) do
      nil -> {:error, not_found()}
      key -> {:ok, key}
    end
  end

  defp expires_at(%{expires_in: nil} = _attrs, config), do: {:ok, default_expiry(config)}

  defp expires_at(%{expires_in: expires_in} = attrs, config) do
    cond do
      attrs[:client] && config[:disable_custom_expires_in] ->
        {:error, error(:custom_expiry_disabled)}

      expires_in < config[:min_expires_in] or expires_in > config[:max_expires_in] ->
        {:error, error(:invalid_expires_in)}

      true ->
        {:ok, DateTime.add(DateTime.utc_now(), expires_in)}
    end
  end

  defp expires_at(_attrs, config), do: {:ok, default_expiry(config)}

  defp default_expiry(config) do
    if config[:default_expires_in],
      do: DateTime.add(DateTime.utc_now(), config[:default_expires_in])
  end

  defp generate(opts, config) do
    case opts[:custom_key_generator] do
      nil ->
        random =
          config[:key_length] |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        (config[:prefix] || "") <> binary_part(random, 0, config[:key_length])

      generator ->
        generator.(%{prefix: config[:prefix], length: config[:key_length]})
    end
  end

  defp custom_valid(nil, _key, _ctx), do: :ok

  defp custom_valid(validator, key, ctx),
    do: if(validator.(key, ctx), do: :ok, else: {:error, error(:invalid_api_key)})

  defp configuration(opts, id) do
    case Options.configuration(opts, id) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, error(:unknown_configuration)}
    end
  end

  defp name_given(name, config) do
    if config[:require_name] and (is_nil(name) or name == ""),
      do: {:error, error(:name_required)},
      else: :ok
  end

  defp metadata_allowed(nil, _config), do: :ok
  defp metadata_allowed(false, _config), do: :ok

  defp metadata_allowed(_metadata, config),
    do: if(config[:enable_metadata], do: :ok, else: {:error, error(:metadata_disabled)})

  defp header_key(conn, headers) do
    Enum.find_value(headers, fn header ->
      case Plug.Conn.get_req_header(conn, header) do
        [key | _] when key != "" -> key
        _none -> nil
      end
    end)
  end

  # Never the hash, nor storage internals.
  defp public(key), do: Map.drop(key, [:key, :allowance, :user, :organization])

  defp server_context(auth), do: Context.new(auth.config())

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  @errors %{
    invalid_api_key: {401, "This API key isn't valid"},
    api_key_disabled: {401, "This API key is disabled"},
    api_key_expired: {401, "This API key has expired"},
    api_key_usage_exceeded: {429, "This API key has no uses left"},
    api_key_rate_limited: {429, "Too many requests with this API key"},
    insufficient_api_key_permissions: {403, "This API key may not do this"},
    api_key_not_found: {404, "API key not found"},
    unknown_configuration: {422, "Unknown API key configuration"},
    name_required: {422, "API keys need a name"},
    metadata_disabled: {422, "API keys can't carry metadata"},
    custom_expiry_disabled: {422, "API keys can't choose their expiry"},
    invalid_expires_in: {422, "This expiry is out of range"}
  }

  defp error(code) do
    {status, message} = Map.fetch!(@errors, code)
    Error.custom(code, status, message)
  end

  defp not_found, do: error(:api_key_not_found)

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
