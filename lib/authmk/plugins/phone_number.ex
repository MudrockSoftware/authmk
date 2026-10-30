defmodule Authmk.Plugins.PhoneNumber do
  @moduledoc """
  Phone numbers: verify them with codes sent by SMS, sign in with a code or a
  password, reset a password with a code.

      use Authmk,
        plugins: [{Authmk.Plugins.PhoneNumber, send_otp: &MyApp.SMS.send_code/2, sign_up_on_verification: true}],
        ...

  Users get a `phone_number` (unique) and `phone_number_verified`. Bring
  your own SMS sender as `send_otp`.

  | Method | Path | Session |
  |---|---|---|
  | POST | `/phone-number/send-otp` | none |
  | POST | `/phone-number/verify` | optional |
  | POST | `/sign-in/phone-number` | none |
  | POST | `/phone-number/request-password-reset` | none |
  | POST | `/phone-number/reset-password` | none |
  | POST | `/phone-number/remove` | required (fresh) |

  `POST /phone-number/verify` with the code:

    * signs in the user with that number (with `disable_session: true`, only
      marks the number verified);
    * creates a user for an unknown number with `sign_up_on_verification:
      true` (with a placeholder email from `temp_email`);
    * with `update_phone_number: true`, gives the signed-in user the number.

  Codes are single use, expire after `otp_expires_in` seconds and stop
  working after `allowed_attempts` wrong guesses. Asking for a password
  reset answers the same whether or not the number is registered.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.PhoneNumber.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Background,
    Context,
    Credentials,
    Endpoint,
    Error,
    OTP,
    PasswordPolicy,
    Serializer,
    Sessions,
    Store
  }

  alias Authmk.Plugins.EmailPassword
  alias Authmk.Plugins.PhoneNumber.Options

  @verify_purpose "phone-number"
  @reset_purpose "phone-number-reset"
  @strict [window: 60, max: 3]

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{
      user: [
        fields: [
          phone_number: [type: :string, unique: true, input: false],
          phone_number_verified: [type: :boolean, default: false, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    number = [phone_number: [type: :string, required: true]]
    code = [code: [type: :string, required: true]]

    [
      endpoint(:send_phone_number_otp, "/phone-number/send-otp", :send_otp,
        rate_limit: @strict,
        params: number
      ),
      endpoint(:verify_phone_number, "/phone-number/verify", :verify,
        session: :optional,
        rate_limit: @strict,
        params:
          number ++
            code ++
            [
              disable_session: [type: :boolean, default: false],
              update_phone_number: [type: :boolean, default: false],
              remember_me: [type: :boolean, default: true]
            ]
      ),
      endpoint(:sign_in_phone_number, "/sign-in/phone-number", :sign_in,
        rate_limit: [window: 10, max: 3],
        params:
          number ++
            [
              password: [type: :string, required: true],
              remember_me: [type: :boolean, default: true]
            ]
      ),
      endpoint(
        :request_phone_password_reset,
        "/phone-number/request-password-reset",
        :request_reset,
        rate_limit: @strict,
        params: number
      ),
      endpoint(:reset_password_phone_number, "/phone-number/reset-password", :reset_password,
        rate_limit: @strict,
        params: number ++ code ++ [new_password: [type: :string, required: true]]
      ),
      endpoint(:remove_phone_number, "/phone-number/remove", :remove,
        session: :required,
        fresh: true
      )
    ]
  end

  @doc false
  def send_otp(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- valid_number(params.phone_number, opts) do
      send_code(ctx, @verify_purpose, params.phone_number, :verification, opts)
    end
  end

  @doc false
  def verify(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- valid_number(params.phone_number, opts),
         :ok <- check_code(ctx, @verify_purpose, opts) do
      if params.update_phone_number,
        do: update_number(ctx),
        else: verified_sign_in(ctx, opts)
    end
  end

  @doc false
  # Unknown numbers and wrong passwords fail the same way.
  def sign_in(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    user = Store.get_by(ctx, :user, phone_number: params.phone_number)

    with :ok <- check_password(ctx, user, params.password),
         :ok <- check_verified(ctx, user, opts) do
      session_answer(ctx, user)
    end
  end

  @doc false
  def request_reset(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    case Store.get_by(ctx, :user, phone_number: params.phone_number) do
      nil -> {:ok, %{status: true}, ctx}
      _user -> send_code(ctx, @reset_purpose, params.phone_number, :password_reset, opts)
    end
  end

  @doc false
  def reset_password(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- valid_password(params.new_password, opts),
         :ok <- check_code(ctx, @reset_purpose, opts),
         %{} = user <- Store.get_by(ctx, :user, phone_number: params.phone_number),
         {:ok, _account} <- Credentials.set_password(ctx, user, params.new_password),
         :ok <-
           Credentials.password_reset(ctx, user, EmailPassword.revoke_sessions_on_reset?(ctx)) do
      {:ok, %{status: true}, ctx}
    else
      nil -> {:error, Error.new(:invalid_otp)}
      error -> error
    end
  end

  @doc false
  def remove(%Context{user: user} = ctx) do
    with {:ok, user} <-
           Store.update(ctx, :user, user, %{phone_number: nil, phone_number_verified: false}) do
      {:ok, %{status: true, user: Serializer.user(ctx, user)}, %{ctx | user: user}}
    end
  end

  defp send_code(ctx, purpose, number, kind, opts) do
    otp_opts = [length: opts[:otp_length], expires_in: opts[:otp_expires_in]]

    with {:ok, code} <- OTP.issue(ctx, purpose, number, otp_opts) do
      message = %{phone_number: number, code: code, purpose: kind}
      Background.plugin_callback(ctx, __MODULE__, :send_otp, message)
      {:ok, %{status: true}, ctx}
    end
  end

  defp check_code(%Context{params: params} = ctx, purpose, opts) do
    OTP.verify(ctx, purpose, params.phone_number, params.code,
      allowed_attempts: opts[:allowed_attempts]
    )
  end

  # The code proved the number: sign in its user, or sign one up.
  defp verified_sign_in(%Context{params: params} = ctx, opts) do
    user = Store.get_by(ctx, :user, phone_number: params.phone_number)

    cond do
      user ->
        verified(ctx, user)

      opts[:sign_up_on_verification] ->
        sign_up(ctx, opts)

      true ->
        {:error, Error.custom(:phone_number_not_found, 404, "No account has this phone number")}
    end
  end

  defp sign_up(%Context{params: params} = ctx, opts) do
    number = params.phone_number

    attrs = %{
      email: opts[:temp_email].(number),
      name: opts[:temp_name].(number),
      phone_number: number,
      phone_number_verified: true
    }

    with {:ok, user} <- Store.insert(ctx, :user, attrs) do
      answer(ctx, user)
    end
  end

  defp verified(ctx, user) do
    with {:ok, user} <- Store.update(ctx, :user, user, %{phone_number_verified: true}) do
      answer(ctx, user)
    end
  end

  defp answer(%Context{params: %{disable_session: true}} = ctx, user),
    do: {:ok, %{status: true, user: Serializer.user(ctx, user)}, ctx}

  defp answer(ctx, user), do: session_answer(ctx, user)

  defp session_answer(%Context{params: params} = ctx, user) do
    case Sessions.sign_in(ctx, user, params.remember_me) do
      {:ok, ctx} -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
      {:challenge, body, ctx} -> {:ok, body, ctx}
      {:error, error} -> {:error, error}
    end
  end

  # The signed-in user takes the number they just proved, unless it's someone else's.
  defp update_number(%Context{user: nil}), do: {:error, Error.new(:unauthorized)}

  defp update_number(%Context{user: user, params: params} = ctx) do
    case Store.get_by(ctx, :user, phone_number: params.phone_number) do
      %{id: id} when id != user.id ->
        {:error,
         Error.custom(:phone_number_taken, 422, "This phone number belongs to another account")}

      _free_or_own ->
        attrs = %{phone_number: params.phone_number, phone_number_verified: true}

        with {:ok, user} <- Store.update(ctx, :user, user, attrs) do
          {:ok, %{status: true, user: Serializer.user(ctx, user)}, %{ctx | user: user}}
        end
    end
  end

  defp check_password(ctx, user, password) do
    case Credentials.check_password(ctx, user, password) do
      :ok -> :ok
      {:error, _invalid} -> {:error, Error.new(:invalid_credentials)}
    end
  end

  defp check_verified(%Context{params: params} = ctx, user, opts) do
    if opts[:require_verification] and not user.phone_number_verified do
      with {:ok, _sent, _ctx} <-
             send_code(ctx, @verify_purpose, params.phone_number, :verification, opts) do
        {:error, Error.custom(:phone_number_not_verified, 403, "Verify your phone number first")}
      end
    else
      :ok
    end
  end

  defp valid_number(number, opts) do
    if opts[:validator].(number),
      do: :ok,
      else: {:error, Error.custom(:invalid_phone_number, 422, "This phone number isn't valid")}
  end

  defp valid_password(password, opts),
    do:
      PasswordPolicy.check_length(
        password,
        opts[:min_password_length],
        opts[:max_password_length]
      )

  defp endpoint(name, path, function, opts) do
    Endpoint.new([name: name, method: :post, path: path, handler: {__MODULE__, function}] ++ opts)
  end
end
