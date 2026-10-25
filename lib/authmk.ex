defmodule Authmk do
  @moduledoc """
  An extensible, plugin-based authentication framework for Elixir.

  Define an auth module:

      defmodule MyApp.Auth do
        use Authmk,
          otp_app: :my_app,
          repo: MyApp.Repo,
          plugins: [Authmk.Plugins.EmailPassword]

        @impl Authmk
        def send_verification_email(%{user: user, url: url}, _ctx) do
          MyApp.Mailer.deliver_verification(user.email, url)
        end
      end

  Start it in your supervision tree, after the repo:

      children = [MyApp.Repo, MyApp.Auth, ...]

  Mount it in your router:

      forward "/auth", MyApp.Auth

  Set runtime options in `config/runtime.exs`:

      config :my_app, MyApp.Auth, base_url: "https://example.com"

  See `Authmk.Options` for every option.

  ## Callbacks

  Every callback has a default, so implement only the ones you need. Hook
  callbacks (`before_endpoint/2`, `after_endpoint/3`, `database_hook/4`) run
  for every request: match what you care about and keep a catch-all clause.
  """

  alias Authmk.{Context, Error}

  @type link :: %{user: struct(), url: String.t(), token: String.t()}

  @doc "Sends the email verification link. The default logs a warning."
  @callback send_verification_email(link(), Context.t()) :: term()

  @doc "Sends the password reset link. The default logs a warning."
  @callback send_reset_password(link(), Context.t()) :: term()

  @doc "Sends the link that confirms an email change to the new address."
  @callback send_change_email_verification(
              %{user: struct(), new_email: String.t(), url: String.t(), token: String.t()},
              Context.t()
            ) :: term()

  @doc "Sends the link that confirms account deletion."
  @callback send_delete_account_verification(link(), Context.t()) :: term()

  @doc "Called after a password reset."
  @callback on_password_reset(%{user: struct()}, Context.t()) :: term()

  @doc """
  Called when someone signs up with an email that already has an account
  while email verification is required. Use it to tell the real owner.
  """
  @callback on_existing_user_sign_up(%{user: struct()}, Context.t()) :: term()

  @doc "Called after a user verifies their email."
  @callback after_email_verification(user :: struct(), Context.t()) :: term()

  @doc "Runs before every endpoint. Return `{:halt, error}` to stop the request."
  @callback before_endpoint(endpoint :: atom(), Context.t()) ::
              {:cont, Context.t()} | {:halt, Error.t()}

  @doc "Runs after every endpoint, and may change its result."
  @callback after_endpoint(endpoint :: atom(), Context.t(), result :: term()) :: term()

  @doc "Runs around database writes. See `c:Authmk.Plugin.database_hook/4`."
  @callback database_hook(event :: atom(), model :: atom(), data :: term(), Context.t()) :: term()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Authmk
      @behaviour Plug

      @authmk_options opts
      @authmk_compile_options Authmk.Options.validate_compile!(opts)
      @authmk_schema Authmk.Schema.Resolver.resolve(__MODULE__, @authmk_compile_options)

      Authmk.Schema.define_library_modules(@authmk_schema, __ENV__)

      @doc false
      def __authmk__(:options), do: @authmk_options
      def __authmk__(:compile_options), do: @authmk_compile_options
      def __authmk__(:schema), do: @authmk_schema

      @doc false
      def child_spec(_arg) do
        %{
          id: __MODULE__,
          start: {Authmk.Supervisor, :start_link, [__MODULE__]},
          type: :supervisor
        }
      end

      @doc "The runtime config. See `Authmk.Config`."
      def config, do: Authmk.Config.fetch!(__MODULE__)

      @impl Plug
      def init(opts), do: opts

      @impl Plug
      def call(conn, _opts), do: Authmk.Router.call(conn, __MODULE__)

      @impl Authmk
      def send_verification_email(_link, _ctx),
        do: Authmk.missing_callback(__MODULE__, :send_verification_email)

      @impl Authmk
      def send_reset_password(_link, _ctx),
        do: Authmk.missing_callback(__MODULE__, :send_reset_password)

      @impl Authmk
      def send_change_email_verification(_link, _ctx),
        do: Authmk.missing_callback(__MODULE__, :send_change_email_verification)

      @impl Authmk
      def send_delete_account_verification(_link, _ctx),
        do: Authmk.missing_callback(__MODULE__, :send_delete_account_verification)

      @impl Authmk
      def on_password_reset(_data, _ctx), do: :ok

      @impl Authmk
      def on_existing_user_sign_up(_data, _ctx), do: :ok

      @impl Authmk
      def after_email_verification(_user, _ctx), do: :ok

      @impl Authmk
      def before_endpoint(_endpoint, ctx), do: {:cont, ctx}

      @impl Authmk
      def after_endpoint(_endpoint, _ctx, result), do: result

      @impl Authmk
      def database_hook(_event, _model, data, _ctx), do: {:ok, data}

      defoverridable send_verification_email: 2,
                     send_reset_password: 2,
                     send_change_email_verification: 2,
                     send_delete_account_verification: 2,
                     on_password_reset: 2,
                     on_existing_user_sign_up: 2,
                     after_email_verification: 2,
                     before_endpoint: 2,
                     after_endpoint: 3,
                     database_hook: 4
    end
  end

  require Logger

  @doc false
  def missing_callback(auth, callback) do
    Logger.warning("#{inspect(auth)} doesn't implement #{callback}/2, so no email was sent")
    :ok
  end
end
