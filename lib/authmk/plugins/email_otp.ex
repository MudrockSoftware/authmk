defmodule Authmk.Plugins.EmailOTP do
  @moduledoc """
  One-time codes by email: sign in with one, verify an email, reset a
  password, change an email.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.EmailOTP, send_otp: &MyApp.Auth.send_email_code/2}
        ],
        ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/email-otp/send-verification-otp` | none |
  | POST | `/email-otp/check-verification-otp` | none |
  | POST | `/sign-in/email-otp` | none |
  | POST | `/email-otp/verify-email` | optional |
  | POST | `/forget-password/email-otp` | none |
  | POST | `/email-otp/reset-password` | none |
  | POST | `/email-otp/request-email-change` | required |
  | POST | `/email-otp/change-email` | required |

  `POST /email-otp/send-verification-otp` takes the `email` and the code's
  `type`: `"sign-in"`, `"email-verification"` or `"forget-password"`. It
  answers the same way whether or not the email has an account, and only
  sends what makes sense (no sign-in code for unknown emails with
  `disable_sign_up`, no reset code for unknown emails). Signing in with a
  code signs up unknown emails, with their email verified.

  A code works once for its type, expires after `expires_in` seconds and
  stops working after `allowed_attempts` wrong guesses.
  `/email-otp/check-verification-otp` checks one without using it up.

  To change their email, a signed-in user asks for a code at the new
  address, then sends it with the new email. The code only works for the
  user who asked.

  With `override_default_email_verification: true`, the codes replace
  authmk's verification links everywhere (sign-up, sign-in with an
  unverified email, `POST /send-verification-email`).

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.EmailOTP.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Background,
    Context,
    Credentials,
    Email,
    Endpoint,
    Error,
    OTP,
    PasswordPolicy,
    Serializer,
    Sessions,
    Store
  }

  alias Authmk.Plugins.EmailOTP.Options
  alias Authmk.Plugins.EmailPassword

  @types %{
    "sign-in" => :sign_in,
    "email-verification" => :email_verification,
    "forget-password" => :forget_password
  }
  @strict [window: 60, max: 3]

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def endpoints(_opts) do
    email = [email: [type: :string, required: true]]
    otp = [otp: [type: :string, required: true]]
    type = [type: [type: :string, required: true]]

    [
      endpoint(:send_verification_otp, "/email-otp/send-verification-otp", :send_otp,
        rate_limit: @strict,
        params: email ++ type
      ),
      endpoint(:check_verification_otp, "/email-otp/check-verification-otp", :check_otp,
        rate_limit: @strict,
        params: email ++ type ++ otp
      ),
      endpoint(:sign_in_email_otp, "/sign-in/email-otp", :sign_in,
        rate_limit: @strict,
        params:
          email ++ otp ++ [name: [type: :string], remember_me: [type: :boolean, default: true]]
      ),
      endpoint(:verify_email_otp, "/email-otp/verify-email", :verify_email,
        session: :optional,
        rate_limit: @strict,
        params: email ++ otp
      ),
      endpoint(:forget_password_email_otp, "/forget-password/email-otp", :forget_password,
        rate_limit: @strict,
        params: email
      ),
      endpoint(:reset_password_email_otp, "/email-otp/reset-password", :reset_password,
        rate_limit: @strict,
        params: email ++ otp ++ [password: [type: :string, required: true]]
      ),
      endpoint(
        :request_email_change_otp,
        "/email-otp/request-email-change",
        :request_email_change,
        session: :required,
        rate_limit: @strict,
        params: [new_email: [type: :string, required: true]]
      ),
      endpoint(:change_email_otp, "/email-otp/change-email", :change_email,
        session: :required,
        rate_limit: @strict,
        params: [new_email: [type: :string, required: true]] ++ otp
      )
    ]
  end

  # Codes instead of links, when asked to.
  @impl true
  def send_email_verification(user, _callback_url, ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    if opts[:override_default_email_verification],
      do: deliver(ctx, user.email, :email_verification, opts),
      else: :cont
  end

  @doc false
  def send_otp(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with {:ok, type} <- type(params.type),
         :ok <- valid_email(email),
         :ok <- maybe_deliver(ctx, email, type, Store.get_by(ctx, :user, email: email), opts) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def check_otp(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with {:ok, type} <- type(params.type),
         :ok <- OTP.check(ctx, purpose(type), email, params.otp, attempts(opts)) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def sign_in(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with :ok <- OTP.verify(ctx, purpose(:sign_in), email, params.otp, attempts(opts)),
         {:ok, user} <- find_or_sign_up(ctx, email, opts),
         {:ok, user} <- mark_verified(ctx, user) do
      case Sessions.sign_in(ctx, user, params.remember_me) do
        {:ok, ctx} -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
        {:challenge, body, ctx} -> {:ok, body, ctx}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc false
  def verify_email(%Context{params: params, config: config} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with :ok <- OTP.verify(ctx, purpose(:email_verification), email, params.otp, attempts(opts)),
         %{} = user <- Store.get_by(ctx, :user, email: email),
         {:ok, user} <- mark_verified(ctx, user) do
      body = %{status: true, user: Serializer.user(ctx, user)}

      if config.email_verification[:auto_sign_in_after_verification] and is_nil(ctx.session),
        do: sign_in_after_verification(ctx, user, body),
        else: {:ok, body, ctx}
    else
      nil -> {:error, Error.new(:invalid_otp)}
      error -> error
    end
  end

  @doc false
  def forget_password(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)
    user = Store.get_by(ctx, :user, email: email)

    with :ok <- maybe_deliver(ctx, email, :forget_password, user, opts) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def reset_password(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with :ok <-
           PasswordPolicy.check_length(
             params.password,
             opts[:min_password_length],
             opts[:max_password_length]
           ),
         :ok <- OTP.verify(ctx, purpose(:forget_password), email, params.otp, attempts(opts)),
         %{} = user <- Store.get_by(ctx, :user, email: email),
         {:ok, _account} <- Credentials.set_password(ctx, user, params.password),
         # Getting the code proved the address too.
         {:ok, _user} <- mark_verified(ctx, user),
         :ok <-
           Credentials.password_reset(ctx, user, EmailPassword.revoke_sessions_on_reset?(ctx)) do
      {:ok, %{success: true}, ctx}
    else
      nil -> {:error, Error.new(:invalid_otp)}
      error -> error
    end
  end

  @doc false
  def request_email_change(%Context{params: params, user: user} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    new_email = Email.normalize(params.new_email)

    # A taken email gets the same answer, so this can't find registered
    # ones; it just gets no code.
    with :ok <- valid_email(new_email),
         :ok <- deliver_unless_taken(ctx, new_email, opts, change_key(user, new_email)) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def change_email(%Context{params: params, user: user} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    new_email = Email.normalize(params.new_email)
    key = change_key(user, new_email)

    with :ok <- OTP.verify(ctx, purpose(:change_email), key, params.otp, attempts(opts)),
         :ok <- available(ctx, new_email),
         {:ok, user} <- Store.update(ctx, :user, user, %{email: new_email, email_verified: true}) do
      {:ok, %{success: true, user: Serializer.user(ctx, user)}, %{ctx | user: user}}
    end
  end

  # What each type sends to whom. Every case answers the same.
  defp maybe_deliver(ctx, email, :sign_in, nil, opts) do
    if opts[:disable_sign_up], do: :ok, else: deliver(ctx, email, :sign_in, opts)
  end

  defp maybe_deliver(_ctx, _email, _type, nil = _unknown_user, _opts), do: :ok

  defp maybe_deliver(_ctx, _email, :email_verification, %{email_verified: true}, _opts), do: :ok

  defp maybe_deliver(ctx, email, type, _user, opts), do: deliver(ctx, email, type, opts)

  defp deliver(ctx, email, type, opts, key \\ nil) do
    otp_opts = [length: opts[:otp_length], expires_in: opts[:expires_in]]

    with {:ok, otp} <- OTP.issue(ctx, purpose(type), key || email, otp_opts) do
      Background.plugin_callback(ctx, __MODULE__, :send_otp, %{email: email, otp: otp, type: type})
    end
  end

  defp find_or_sign_up(ctx, email, opts) do
    case Store.get_by(ctx, :user, email: email) do
      %{} = user -> {:ok, user}
      nil -> sign_up(ctx, email, opts[:disable_sign_up])
    end
  end

  defp sign_up(_ctx, _email, true = _disabled), do: {:error, Error.new(:sign_up_disabled)}

  defp sign_up(%Context{params: params} = ctx, email, false) do
    name = params.name || email |> String.split("@") |> hd()
    Store.insert(ctx, :user, %{email: email, name: name, email_verified: true})
  end

  defp sign_in_after_verification(ctx, user, body) do
    case Sessions.sign_in(ctx, user) do
      {:ok, ctx} -> {:ok, body, ctx}
      {:challenge, challenge, ctx} -> {:ok, Map.merge(body, challenge), ctx}
      {:error, error} -> {:error, error}
    end
  end

  defp mark_verified(_ctx, %{email_verified: true} = user), do: {:ok, user}
  defp mark_verified(ctx, user), do: Store.update(ctx, :user, user, %{email_verified: true})

  defp available(ctx, email) do
    if Store.get_by(ctx, :user, email: email),
      do: {:error, Error.new(:user_already_exists)},
      else: :ok
  end

  defp deliver_unless_taken(ctx, new_email, opts, key) do
    if available(ctx, new_email) == :ok,
      do: deliver(ctx, new_email, :change_email, opts, key),
      else: :ok
  end

  # A change code is bound to the user who asked, from the address they had:
  # a later change makes older codes useless.
  defp change_key(user, new_email), do: "#{user.id}:#{user.email}:#{new_email}"

  defp type(type) do
    case Map.fetch(@types, type) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, Error.custom(:invalid_otp_type, 400, "Unknown code type")}
    end
  end

  defp valid_email(email) do
    if Email.valid?(email), do: :ok, else: {:error, Error.new(:invalid_email)}
  end

  defp purpose(type), do: "email-otp:#{type}"

  defp attempts(opts), do: [allowed_attempts: opts[:allowed_attempts]]

  defp endpoint(name, path, function, opts) do
    Endpoint.new([name: name, method: :post, path: path, handler: {__MODULE__, function}] ++ opts)
  end
end
