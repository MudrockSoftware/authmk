defmodule Authmk.Config do
  @moduledoc """
  Runtime configuration of an auth module.

  Built once when the auth module starts: `use Authmk` options merged with
  application config (`config :my_app, MyApp.Auth, ...`), validated, and
  stored in `:persistent_term` for fast reads.
  """

  alias Authmk.{BaseURL, Options, Origin, Secrets}
  alias Authmk.OAuth.Providers
  alias Authmk.Schema.Definition
  alias Authmk.Storage.ETS

  # Never print secrets, for example in crash reports.
  @derive {Inspect, except: [:secrets]}

  @enforce_keys [:auth, :repo, :schema, :plugins, :endpoints]
  defstruct [
    :auth,
    :otp_app,
    :repo,
    :schema,
    :plugins,
    :endpoints,
    :trusted_origins,
    :hook_modules,
    :secrets,
    :secondary_storage,
    :verification,
    :errors,
    :social_providers,
    :account,
    :base_url,
    :base_path,
    :app_name,
    :disabled_paths,
    :background,
    :password_hasher,
    :find_many_limit,
    :email_verification,
    :session,
    :user,
    :cookies,
    :rate_limit,
    :advanced
  ]

  @type t :: %__MODULE__{}

  @doc "Builds the config for `auth`. Raises with a clear message on invalid config."
  @spec load(module()) :: t()
  def load(auth) do
    use_opts = auth.__authmk__(:options)
    compile = auth.__authmk__(:compile_options)
    app_opts = Application.get_env(compile[:otp_app], auth, [])

    case Enum.filter(Keyword.keys(app_opts), &(&1 in Options.compile_keys())) do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "#{inspect(keys)} can only be set in `use Authmk`, not in application config"
    end

    runtime = Options.validate_runtime!(deep_merge(use_opts, app_opts))

    :ok = BaseURL.validate!(runtime[:base_url])

    plugins = Enum.map(compile[:plugins], &init_plugin/1)
    check_dependencies!(plugins)

    config =
      struct!(
        __MODULE__,
        [
          auth: auth,
          otp_app: compile[:otp_app],
          repo: compile[:repo],
          schema: auth.__authmk__(:schema),
          plugins: plugins,
          endpoints: [],
          secrets: Secrets.resolve!(runtime)
        ] ++ Keyword.drop(runtime, [:secret, :secrets])
      )

    config = %{
      config
      | endpoints: endpoints(config),
        trusted_origins: trusted_origins(config),
        hook_modules: hook_modules(config),
        social_providers: Providers.build(config.social_providers),
        secondary_storage: storage(auth, config.secondary_storage)
    }

    check_storage!(config)
    config
  end

  # Hook order: authmk's own, then plugins in config order, then the auth module.
  # Loaded now: `function_exported?/3` is false for modules not loaded yet.
  defp hook_modules(config) do
    modules = [Authmk.CoreHooks | Enum.map(config.plugins, &elem(&1, 0))] ++ [config.auth]
    Enum.each(modules, &Code.ensure_loaded!/1)
    modules
  end

  # The ETS store needs the table its auth module starts.
  defp storage(_auth, nil), do: nil

  defp storage(auth, ETS), do: {ETS, table: ETS.table(auth)}
  defp storage(auth, {ETS, _opts}), do: storage(auth, ETS)
  defp storage(_auth, {module, opts}), do: {module, opts}
  defp storage(_auth, module), do: {module, []}

  defp check_storage!(config) do
    rate_limit_storage = config.rate_limit[:storage]
    plugins = Enum.map(config.plugins, &elem(&1, 0))

    cond do
      rate_limit_storage == :secondary_storage and is_nil(config.secondary_storage) ->
        raise ArgumentError, "rate_limit: [storage: :secondary_storage] needs secondary_storage"

      rate_limit_storage == :database and Authmk.Plugins.DatabaseRateLimit not in plugins ->
        raise ArgumentError,
              "rate_limit: [storage: :database] needs the Authmk.Plugins.DatabaseRateLimit plugin"

      config.secondary_storage && not config.session[:store_in_database] &&
          Definition.model!(config.schema, :session).primary_key == :id ->
        raise ArgumentError,
              "sessions kept only in secondary storage can't have integer ids. " <>
                "Use schema: [session: [primary_key: :uuid_v7]], or session: [store_in_database: true]"

      true ->
        :ok
    end
  end

  @doc "Stores a loaded config."
  @spec put(t()) :: :ok
  def put(%__MODULE__{auth: auth} = config), do: :persistent_term.put({__MODULE__, auth}, config)

  @doc "Removes a stored config."
  @spec erase(module()) :: :ok
  def erase(auth) do
    :persistent_term.erase({__MODULE__, auth})
    :ok
  end

  @doc "Returns the config of a started auth module."
  @spec fetch!(module()) :: t()
  def fetch!(auth) do
    :persistent_term.get({__MODULE__, auth})
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(auth)} is not started. Add it to your supervision tree.",
              __STACKTRACE__
  end

  # Loads the plugin first: `function_exported?/3`, used here and by hooks,
  # is false for modules that aren't loaded yet.
  defp init_plugin({plugin, opts}) do
    Code.ensure_loaded!(plugin)
    if function_exported?(plugin, :init, 1), do: {plugin, plugin.init(opts)}, else: {plugin, opts}
  end

  defp check_dependencies!(plugins) do
    enabled = Enum.map(plugins, &elem(&1, 0))

    for {plugin, _} <- plugins,
        function_exported?(plugin, :depends_on, 0),
        dependency <- plugin.depends_on(),
        dependency not in enabled do
      raise ArgumentError, "#{inspect(plugin)} needs #{inspect(dependency)} to be enabled"
    end

    :ok
  end

  defp endpoints(config) do
    plugin_endpoints =
      for {plugin, opts} <- config.plugins,
          function_exported?(plugin, :endpoints, 1),
          endpoint <- plugin.endpoints(opts) do
        %{endpoint | plugin: plugin}
      end

    endpoints =
      Enum.reject(Authmk.Endpoints.all() ++ plugin_endpoints, &(&1.path in config.disabled_paths))

    for {key, [_, _ | _]} <- Enum.group_by(endpoints, &{&1.method, &1.path}) do
      raise ArgumentError, "two endpoints are declared for #{inspect(key)}"
    end

    for {name, [_, _ | _]} <- Enum.group_by(endpoints, & &1.name) do
      raise ArgumentError, "two endpoints are named #{inspect(name)}"
    end

    endpoints
  end

  defp trusted_origins(config) do
    plugin_origins =
      for {plugin, opts} <- config.plugins,
          function_exported?(plugin, :trusted_origins, 1),
          origin <- plugin.trusted_origins(opts),
          do: origin

    (BaseURL.trusted_origins(config.base_url) ++ config.trusted_origins ++ plugin_origins)
    |> Enum.map(&Origin.normalize/1)
    |> Enum.uniq()
  end

  @doc false
  @spec deep_merge(keyword(), keyword()) :: keyword()
  def deep_merge(left, right) do
    Keyword.merge(left, right, fn _key, l, r ->
      if Keyword.keyword?(l) and Keyword.keyword?(r), do: deep_merge(l, r), else: r
    end)
  end
end
