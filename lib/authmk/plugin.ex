defmodule Authmk.Plugin do
  @moduledoc """
  Behaviour for authmk plugins. Every callback is optional.

      defmodule MyPlugin do
        use Authmk.Plugin

        @impl true
        def schema(_opts), do: %{user: [fields: [nickname: [type: :string]]]}

        @impl true
        def endpoints(_opts) do
          [Authmk.Endpoint.new(name: :hello, method: :get, path: "/hello", handler: {__MODULE__, :hello})]
        end

        def hello(ctx), do: {:ok, %{hello: "world"}, ctx}
      end

  Hooks (`before_endpoint/2`, `after_endpoint/3`, `database_hook/4`) run for
  every request, so match on the endpoint or model you care about and add a
  catch-all clause that passes everything else through.
  """

  alias Authmk.{Context, Endpoint, Error}

  @type opts :: keyword()
  @type result ::
          {:ok, term(), Context.t()}
          | {:redirect, String.t(), Context.t()}
          | {:error, Error.t()}
          | {:error, Error.t(), Context.t()}

  @doc "Validates the plugin's options at startup. Raise on invalid options."
  @callback init(opts()) :: opts()

  @doc "Models and fields the plugin adds. Called at compile time."
  @callback schema(opts()) :: %{atom() => keyword()}

  @doc "Endpoints the plugin serves."
  @callback endpoints(opts()) :: [Endpoint.t()]

  @doc "Origins the plugin trusts, in addition to the configured ones."
  @callback trusted_origins(opts()) :: [String.t()]

  @doc "Plugins that must be enabled for this one to work."
  @callback depends_on() :: [module()]

  @doc "Runs before an endpoint. Return `{:halt, error}` to stop the request."
  @callback before_endpoint(endpoint :: atom(), Context.t()) ::
              {:cont, Context.t()} | {:halt, Error.t()}

  @doc "Runs after an endpoint, and may change its result."
  @callback after_endpoint(endpoint :: atom(), Context.t(), result()) :: result()

  @doc """
  Runs around database writes. `event` is one of `:before_create`,
  `:before_update`, `:before_delete` (return `{:ok, data}` or `{:error, error}`)
  or `:after_create`, `:after_update`, `:after_delete` (return value ignored).
  """
  @callback database_hook(event :: atom(), model :: atom(), data :: term(), Context.t()) ::
              {:ok, term()} | {:error, Error.t()} | term()

  @optional_callbacks init: 1,
                      schema: 1,
                      endpoints: 1,
                      trusted_origins: 1,
                      depends_on: 0,
                      before_endpoint: 2,
                      after_endpoint: 3,
                      database_hook: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour Authmk.Plugin
    end
  end
end
