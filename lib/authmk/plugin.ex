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

  Hooks (`on_request/1`, `on_response/2`, `before_endpoint/2`,
  `after_endpoint/3`, `database_hook/4`) run for every request, so match on
  the endpoint or model you care about and add a catch-all clause that passes
  everything else through. For checks shared by several of your own
  endpoints, give them a `middleware:` list instead (see `Authmk.Endpoint`).
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

  @doc """
  Runs for every request to the auth router, before any built-in check
  (origin, rate limit, session). `ctx.endpoint` is set; `ctx.params` and the
  session are not loaded yet. Return `{:halt, error}` to stop the request.
  """
  @callback on_request(Context.t()) :: {:cont, Context.t()} | {:halt, Error.t()}

  @doc "Changes the response (headers, status) just before it is sent."
  @callback on_response(Plug.Conn.t(), Context.t()) :: Plug.Conn.t()

  @doc "Runs before an endpoint. Return `{:halt, error}` to stop the request."
  @callback before_endpoint(endpoint :: atom(), Context.t()) ::
              {:cont, Context.t()} | {:halt, Error.t()}

  @doc "Runs after an endpoint, and may change its result."
  @callback after_endpoint(endpoint :: atom(), Context.t(), result()) :: result()

  @doc """
  Runs when a sign-in is about to create a session, whatever the sign-in
  method. Return `{:challenge, body, ctx}` to ask for another step first,
  like a second factor: no session is created, and the sign-in answers with
  `body`. Sign-ins that end in a redirect (social sign-in) send the browser
  to `body.redirect_url` when there is one.
  """
  @callback sign_in_challenge(user :: struct(), remember_me :: boolean(), Context.t()) ::
              {:cont, Context.t()} | {:challenge, map(), Context.t()} | {:error, Error.t()}

  @doc """
  Authenticates a request without a session cookie, like an API key in a
  header. Runs wherever authmk loads the session: the auth router and
  `Authmk.Plug.FetchSession`. Return `{:ok, session, user}` to sign the
  request in (the session is built in memory, not stored), `:none` to fall
  back to the session cookie, or `{:error, error}` to refuse the request.
  `{:principal, principal}` authenticates something that isn't a user, like
  a service account: there is no session or user then, and
  `Authmk.Plug.FetchSession` assigns it as `current_principal`.
  """
  @callback authenticate_request(Context.t()) ::
              {:ok, session :: struct(), user :: struct()}
              | {:principal, term()}
              | :none
              | {:error, Error.t()}

  @doc """
  Runs before authmk emails a verification link (on sign-up, on sign-in
  with unverified email, or when asked). Return `:ok` after sending your own
  instead, like a code; `:cont` lets the link go out.
  """
  @callback send_email_verification(
              user :: struct(),
              callback_url :: String.t() | nil,
              Context.t()
            ) ::
              :cont | :ok | {:error, Error.t()}

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
                      on_request: 1,
                      on_response: 2,
                      before_endpoint: 2,
                      after_endpoint: 3,
                      sign_in_challenge: 3,
                      authenticate_request: 1,
                      send_email_verification: 3,
                      database_hook: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour Authmk.Plugin
    end
  end
end
