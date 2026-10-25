defmodule Authmk.Config do
  @moduledoc """
  Runtime configuration of an auth module.

  Built once when the auth module starts: `use Authmk` options merged with
  application config (`config :my_app, MyApp.Auth, ...`), validated, and
  stored in `:persistent_term` for fast reads.
  """

  alias Authmk.{Options, Origin}

  @enforce_keys [:auth, :repo, :schema, :plugins, :endpoints]
  defstruct [
    :auth,
    :otp_app,
    :repo,
    :schema,
    :plugins,
    :endpoints,
    :trusted_origins,
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
          endpoints: []
        ] ++ runtime
      )

    %{config | endpoints: endpoints(config), trusted_origins: trusted_origins(config)}
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

    [config.base_url | config.trusted_origins ++ plugin_origins]
    |> Enum.map(&Origin.normalize!/1)
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
