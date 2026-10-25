defmodule Authmk.Plugins.EmailPassword do
  @moduledoc """
  Sign-up and sign-in with email and password, password reset and password
  change.

      use Authmk, plugins: [{Authmk.Plugins.EmailPassword, require_email_verification: true}], ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-up/email` | none |
  | POST | `/sign-in/email` | none |
  | POST | `/request-password-reset` | none |
  | GET | `/reset-password/:token` | none |
  | POST | `/reset-password` | none |
  | POST | `/change-password` | required |
  | POST | `/verify-password` | required |

  Responses never reveal whether an email is registered: password reset
  always succeeds, sign-in failures are all `invalid_credentials` and take
  the same time, and with `require_email_verification` sign-up answers the
  same way for new and existing emails.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.EmailPassword.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Background,
    Context,
    Credentials,
    Email,
    EmailVerification,
    Endpoint,
    Error,
    Input,
    Origin,
    PasswordPolicy,
    Serializer,
    Sessions,
    Store,
    URL,
    Verification
  }

  alias Authmk.Plugins.EmailPassword.Options

  @reset_purpose "reset-password"
  @strict [window: 10, max: 3]

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def endpoints(_opts) do
    [
      endpoint(:sign_up_email, :post, "/sign-up/email", :sign_up,
        rate_limit: @strict,
        params: [
          email: [type: :string, required: true],
          password: [type: :string, required: true],
          callback_url: [type: :string],
          remember_me: [type: :boolean, default: true]
        ]
      ),
      endpoint(:sign_in_email, :post, "/sign-in/email", :sign_in,
        rate_limit: @strict,
        params: [
          email: [type: :string, required: true],
          password: [type: :string, required: true],
          callback_url: [type: :string],
          remember_me: [type: :boolean, default: true]
        ]
      ),
      endpoint(:request_password_reset, :post, "/request-password-reset", :request_password_reset,
        rate_limit: @strict,
        params: [email: [type: :string, required: true], redirect_to: [type: :string]]
      ),
      endpoint(:reset_password_callback, :get, "/reset-password/:token", :reset_password_callback,
        params: [
          token: [type: :string, required: true],
          callback_url: [type: :string, required: true]
        ]
      ),
      endpoint(:reset_password, :post, "/reset-password", :reset_password,
        rate_limit: @strict,
        params: [
          token: [type: :string, required: true],
          new_password: [type: :string, required: true]
        ]
      ),
      endpoint(:change_password, :post, "/change-password", :change_password,
        session: :required,
        rate_limit: @strict,
        params: [
          current_password: [type: :string, required: true],
          new_password: [type: :string, required: true],
          revoke_other_sessions: [type: :boolean, default: false]
        ]
      ),
      endpoint(:verify_password, :post, "/verify-password", :verify_password,
        session: :required,
        rate_limit: @strict,
        params: [password: [type: :string, required: true]]
      )
    ]
  end

  @doc """
  Gives a user without a password one, for example someone who signed up
  with a social provider. Server-side only: call it from your own code after
  checking who is asking.

      Authmk.Plugins.EmailPassword.set_password(MyApp.Auth, user, "a new password")
  """
  @spec set_password(module(), struct(), String.t()) :: {:ok, struct()} | {:error, Error.t()}
  def set_password(auth, user, password) do
    ctx = Context.new(auth.config())

    with :ok <- validate_password(password, Context.plugin_opts(ctx, __MODULE__)),
         :ok <- no_password_yet(ctx, user) do
      Credentials.set_password(ctx, user, password)
    end
  end

  defp no_password_yet(ctx, user) do
    case Credentials.account(ctx, user.id) do
      %{password: hash} when is_binary(hash) -> {:error, Error.new(:password_already_set)}
      _no_password -> :ok
    end
  end

  @doc false
  def sign_up(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with :ok <- check(not opts[:disable_sign_up], :sign_up_disabled),
         :ok <- check(Email.valid?(email), :invalid_email),
         :ok <- validate_password(params.password, opts),
         :ok <- Origin.check_redirect(ctx, params.callback_url) do
      case Store.get_by(ctx, :user, email: email) do
        nil -> create_user(ctx, opts, email)
        user -> existing_user(ctx, opts, user)
      end
    end
  end

  @doc false
  def sign_in(%Context{params: params} = ctx) do
    password_sign_in(ctx, Store.get_by(ctx, :user, email: Email.normalize(params.email)))
  end

  @doc false
  # Signs in `user` (or fails the same way for `nil`) with `password`,
  # `callback_url` and `remember_me` from the params. For plugins that find
  # the user another way, like by username.
  def password_sign_in(%Context{params: params} = ctx, user) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- Origin.check_redirect(ctx, params.callback_url),
         :ok <- check_credentials(ctx, user, params.password),
         :ok <- check_verified(ctx, opts, user) do
      case Sessions.sign_in(ctx, user, params.remember_me) do
        {:ok, ctx} ->
          {:ok, %{user: Serializer.user(ctx, user), redirect: params.callback_url}, ctx}

        {:challenge, body, ctx} ->
          {:ok, body, ctx}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc false
  def request_password_reset(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    user = Store.get_by(ctx, :user, email: Email.normalize(params.email))

    # Unknown emails get the same answer, so this can't find registered ones.
    with :ok <- Origin.check_redirect(ctx, params.redirect_to),
         :ok <- send_reset_link(ctx, opts, user, params.redirect_to) do
      {:ok, %{status: true}, ctx}
    end
  end

  @doc false
  def reset_password_callback(%Context{params: params} = ctx) do
    with :ok <- Origin.check_redirect(ctx, params.callback_url) do
      query =
        case Verification.peek(ctx, @reset_purpose, params.token) do
          {:ok, _data} -> [token: params.token]
          {:error, error} -> [error: error.code]
        end

      {:redirect, URL.append_query(params.callback_url, query), ctx}
    end
  end

  @doc false
  def reset_password(%Context{params: params, config: config} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- validate_password(params.new_password, opts),
         {:ok, %{"user_id" => user_id}} <- Verification.consume(ctx, @reset_purpose, params.token),
         %{} = user <- Store.get_by(ctx, :user, id: user_id),
         {:ok, _account} <- Credentials.set_password(ctx, user, params.new_password) do
      if opts[:revoke_sessions_on_password_reset], do: Sessions.revoke_all(ctx, user.id)
      Background.run(ctx, fn -> config.auth.on_password_reset(%{user: user}, ctx) end)
      {:ok, %{status: true}, ctx}
    else
      nil -> {:error, Error.new(:invalid_token)}
      error -> error
    end
  end

  @doc false
  def change_password(%Context{params: params, user: user} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- Credentials.check_password(ctx, user, params.current_password),
         :ok <- validate_password(params.new_password, opts),
         {:ok, _account} <- Credentials.set_password(ctx, user, params.new_password) do
      if params.revoke_other_sessions, do: Sessions.revoke_others(ctx, user.id, ctx.session.id)
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def verify_password(%Context{params: params} = ctx) do
    with :ok <- Credentials.check_password(ctx, ctx.user, params.password) do
      {:ok, %{status: true}, ctx}
    end
  end

  defp create_user(ctx, opts, email) do
    attrs = ctx |> Input.attrs(:user) |> Map.put("email", email)

    result =
      Store.transaction(ctx, fn ->
        with {:ok, user} <- Store.insert(ctx, :user, attrs),
             {:ok, _account} <- Credentials.set_password(ctx, user, ctx.params.password) do
          {:ok, user}
        end
      end)

    with {:ok, user} <- result do
      after_sign_up(ctx, opts, user)
    end
  end

  defp after_sign_up(%Context{config: config, params: params} = ctx, opts, user) do
    verification_required = opts[:require_email_verification]
    send? = verification_required or config.email_verification[:send_on_sign_up]

    with :ok <- EmailVerification.maybe_send_verification(ctx, send?, user, params.callback_url) do
      cond do
        verification_required -> {:ok, %{status: true}, ctx}
        opts[:auto_sign_in] -> sign_in_new_user(ctx, user)
        true -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
      end
    end
  end

  defp sign_in_new_user(ctx, user) do
    case Sessions.sign_in(ctx, user, ctx.params.remember_me) do
      {:ok, ctx} -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
      {:challenge, body, ctx} -> {:ok, body, ctx}
      {:error, error} -> {:error, error}
    end
  end

  # With required verification, an existing email gets the same answer as a
  # new one. The real owner is told through `on_existing_user_sign_up`.
  defp existing_user(%Context{config: config} = ctx, opts, user) do
    # Hash anyway, so the response takes as long as a real sign-up.
    config.password_hasher.hash(ctx.params.password)

    if opts[:require_email_verification] do
      Background.run(ctx, fn -> config.auth.on_existing_user_sign_up(%{user: user}, ctx) end)
      {:ok, %{status: true}, ctx}
    else
      {:error, Error.new(:user_already_exists)}
    end
  end

  defp check_credentials(ctx, user, password) do
    case Credentials.check_password(ctx, user, password) do
      :ok -> :ok
      {:error, _invalid_password} -> {:error, Error.new(:invalid_credentials)}
    end
  end

  defp check_verified(%Context{config: config, params: params} = ctx, opts, user) do
    if opts[:require_email_verification] and not user.email_verified do
      send? = config.email_verification[:send_on_sign_in]

      with :ok <- EmailVerification.maybe_send_verification(ctx, send?, user, params.callback_url) do
        {:error, Error.new(:email_not_verified)}
      end
    else
      :ok
    end
  end

  defp send_reset_link(_ctx, _opts, nil = _unknown_user, _redirect_to), do: :ok

  defp send_reset_link(%Context{config: config} = ctx, opts, user, redirect_to) do
    data = %{"user_id" => to_string(user.id)}
    expires_in = opts[:reset_password_token_expires_in]

    with {:ok, token} <- Verification.create(ctx, @reset_purpose, data, expires_in) do
      url = URL.endpoint(ctx, "/reset-password/#{token}", callback_url: redirect_to)

      Background.run(ctx, fn ->
        config.auth.send_reset_password(%{user: user, url: url, token: token}, ctx)
      end)
    end
  end

  defp validate_password(password, opts),
    do:
      PasswordPolicy.check_length(
        password,
        opts[:min_password_length],
        opts[:max_password_length]
      )

  defp check(true, _code), do: :ok
  defp check(false, code), do: {:error, Error.new(code)}

  defp endpoint(name, method, path, function, opts) do
    Endpoint.new(
      [name: name, method: method, path: path, handler: {__MODULE__, function}] ++ opts
    )
  end
end
