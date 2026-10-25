defmodule Authmk.Plugins.TwoFactor do
  @moduledoc """
  Two-factor authentication: authenticator apps (TOTP), one-time codes by
  email or SMS, backup codes and trusted devices.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.TwoFactor, issuer: "My App", send_otp: &MyApp.Auth.send_two_factor_code/2}
        ],
        ...

  ## Turning it on

  A signed-in user calls `POST /two-factor/enable` with their password, and
  gets an `otpauth://` URI (show it as a QR code) and backup codes. 2FA is
  on once they confirm a first code with `POST /two-factor/verify-totp`, or
  at once with `skip_verification_on_enable: true`. Users who'd rather get
  codes by email or SMS confirm with `POST /two-factor/send-otp` and
  `POST /two-factor/verify-otp` instead.

  ## Signing in

  Once 2FA is on, every sign-in (password, social, any other method) answers
  with `%{two_factor_redirect: true, two_factor_methods: [...]}` instead of
  a session, and sets a `two_factor` cookie. The user then sends a code to
  `/two-factor/verify-totp`, `/two-factor/verify-otp` (after
  `/two-factor/send-otp`) or `/two-factor/verify-backup-code`, which signs
  them in. With `trust_device: true`, this browser skips 2FA for
  `trust_device_days`. After `max_attempts` wrong codes, or
  `challenge_expires_in` seconds, the user signs in again from the start.

  Social sign-in ends in a redirect: set `two_factor_page` to send users to
  your page for the second step.

  | Method | Path | Session |
  |---|---|---|
  | POST | `/two-factor/enable` | required |
  | POST | `/two-factor/disable` | required |
  | POST | `/two-factor/get-totp-uri` | required |
  | POST | `/two-factor/verify-totp` | optional (sign-in, or turning 2FA on) |
  | POST | `/two-factor/send-otp` | optional (sign-in, or turning 2FA on) |
  | POST | `/two-factor/verify-otp` | optional (sign-in, or turning 2FA on) |
  | POST | `/two-factor/verify-backup-code` | none (sign-in) |
  | POST | `/two-factor/generate-backup-codes` | required |
  | POST | `/two-factor/view-backup-codes` | required |

  Managing 2FA takes the user's `password`. With `allow_passwordless: true`,
  users without one (social sign-in only) use a fresh session instead.

  The TOTP secret, the backup codes and pending one-time codes are stored
  encrypted. An authenticator
  code works once, and a backup code is used up, even under concurrent
  requests.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.TwoFactor.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Background,
    Context,
    Credentials,
    Crypto,
    Endpoint,
    Error,
    Serializer,
    Sessions,
    Store
  }

  alias Authmk.Plugins.TwoFactor.{BackupCodes, Challenge, Options, TOTP, TrustedDevice}

  @strict [window: 10, max: 3]
  @otp_purpose "two-factor-otp"

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{
      user: [fields: [two_factor_enabled: [type: :boolean, default: false, input: false]]],
      two_factor: [
        plural: "two_factors",
        fields: [
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            unique: true,
            input: false
          ],
          # Encrypted TOTP secret.
          secret: [type: :text, required: true, returned: false, redact: true, input: false],
          # Encrypted JSON list of the unused backup codes.
          backup_codes: [type: :text, required: true, returned: false, redact: true, input: false],
          # The period of the last accepted TOTP code: older codes can't be replayed.
          totp_last_step: [type: :integer, returned: false, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    password = [password: [type: :string]]
    code = [code: [type: :string, required: true], trust_device: [type: :boolean, default: false]]

    [
      endpoint(:enable_two_factor, "/two-factor/enable", :enable,
        session: :required,
        params: password ++ [issuer: [type: :string]]
      ),
      endpoint(:disable_two_factor, "/two-factor/disable", :disable,
        session: :required,
        params: password
      ),
      endpoint(:get_totp_uri, "/two-factor/get-totp-uri", :totp_uri,
        session: :required,
        params: password
      ),
      endpoint(:verify_totp, "/two-factor/verify-totp", :verify_totp,
        session: :optional,
        rate_limit: @strict,
        params: code
      ),
      endpoint(:send_two_factor_otp, "/two-factor/send-otp", :send_otp,
        session: :optional,
        rate_limit: @strict
      ),
      endpoint(:verify_two_factor_otp, "/two-factor/verify-otp", :verify_otp,
        session: :optional,
        rate_limit: @strict,
        params: code
      ),
      endpoint(:verify_backup_code, "/two-factor/verify-backup-code", :verify_backup_code,
        rate_limit: @strict,
        params: code
      ),
      endpoint(
        :generate_backup_codes,
        "/two-factor/generate-backup-codes",
        :generate_backup_codes,
        session: :required,
        params: password
      ),
      endpoint(:view_backup_codes, "/two-factor/view-backup-codes", :view_backup_codes,
        session: :required,
        params: password
      )
    ]
  end

  # Every sign-in of a user with 2FA on stops here, unless the browser is trusted.
  @impl true
  def sign_in_challenge(user, remember_me, ctx) do
    if Map.get(user, :two_factor_enabled),
      do: challenge(ctx, user, remember_me, Context.plugin_opts(ctx, __MODULE__)),
      else: {:cont, ctx}
  end

  defp challenge(ctx, user, remember_me, opts) do
    two_factor = two_factor(ctx, user)

    if two_factor && TrustedDevice.trusted?(ctx, user, two_factor) do
      {:cont, TrustedDevice.put(ctx, user, two_factor, opts)}
    else
      with {:ok, ctx} <- Challenge.put(ctx, Challenge.new(user, remember_me, "sign_in", opts)) do
        {:challenge, challenge_body(opts), ctx}
      end
    end
  end

  @doc false
  def enable(%Context{config: config, user: user, params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- confirm(ctx, opts),
         :ok <- not_enabled(user) do
      secret = TOTP.new_secret()
      codes = BackupCodes.generate(opts)

      attrs = %{
        user_id: user.id,
        secret: TOTP.encrypt(config, secret),
        backup_codes: BackupCodes.encrypt(config, codes)
      }

      with {:ok, _two_factor} <- set_up(ctx, attrs, opts[:skip_verification_on_enable]) do
        uri = TOTP.uri(secret, user, params.issuer || issuer(ctx, opts), opts[:totp_period])
        {:ok, %{totp_uri: uri, backup_codes: codes}, ctx}
      end
    end
  end

  @doc false
  def disable(%Context{user: user} = ctx) do
    with :ok <- confirm(ctx, Context.plugin_opts(ctx, __MODULE__)),
         {:ok, _transaction} <-
           Store.transaction(ctx, fn ->
             _deleted = Store.delete_all(ctx, :two_factor, user_id: user.id)
             Store.update(ctx, :user, user, %{two_factor_enabled: false})
           end) do
      {:ok, %{status: true}, TrustedDevice.forget(ctx)}
    end
  end

  @doc false
  def totp_uri(%Context{config: config, user: user} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- confirm(ctx, opts),
         {:ok, two_factor} <- set_up(ctx, user) do
      secret = TOTP.decrypt(config, two_factor.secret)
      {:ok, %{totp_uri: TOTP.uri(secret, user, issuer(ctx, opts), opts[:totp_period])}, ctx}
    end
  end

  @doc false
  def verify_totp(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    check = fn ctx, _data, two_factor ->
      two_factor != nil and TOTP.verify(ctx, two_factor, params.code, opts[:totp_period])
    end

    case Challenge.take(ctx) do
      {:ok, data, ctx} -> answer(ctx, data, opts, check)
      :none -> confirm_setup_with_totp(ctx, opts)
    end
  end

  @doc false
  def send_otp(ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    code = otp_code()
    expires_at = System.system_time(:second) + opts[:otp_expires_in]

    with {:ok, sender} <- otp_sender(opts),
         {:ok, data, ctx} <- challenge_for_otp(ctx, opts),
         %{} = user <- Store.get_by(ctx, :user, id: data["user_id"]),
         otp = Crypto.encrypt(ctx.config, @otp_purpose, code),
         data = Map.merge(data, %{"otp" => otp, "otp_expires_at" => expires_at}),
         {:ok, ctx} <- Challenge.put(ctx, data) do
      Background.run(ctx, fn -> sender.(%{user: user, otp: code}, ctx) end)
      {:ok, %{status: true}, ctx}
    else
      nil -> {:error, Challenge.expired()}
      error -> error
    end
  end

  @doc false
  def verify_otp(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    case Challenge.take(ctx) do
      {:ok, data, ctx} ->
        answer(ctx, data, opts, fn ctx, data, _tf -> otp_matches?(ctx, data, params.code) end)

      :none ->
        {:error, Challenge.expired()}
    end
  end

  @doc false
  def verify_backup_code(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    case Challenge.take(ctx) do
      {:ok, %{"kind" => "sign_in"} = data, ctx} ->
        answer(ctx, data, opts, fn ctx, _data, tf ->
          tf != nil and BackupCodes.use(ctx, tf, params.code)
        end)

      _none ->
        {:error, Challenge.expired()}
    end
  end

  @doc false
  def generate_backup_codes(%Context{config: config, user: user} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- confirm(ctx, opts),
         {:ok, two_factor} <- set_up(ctx, user) do
      codes = BackupCodes.generate(opts)

      with {:ok, _two_factor} <-
             Store.update(ctx, :two_factor, two_factor, %{
               backup_codes: BackupCodes.encrypt(config, codes)
             }) do
        {:ok, %{backup_codes: codes}, ctx}
      end
    end
  end

  @doc false
  def view_backup_codes(%Context{config: config, user: user} = ctx) do
    with :ok <- confirm(ctx, Context.plugin_opts(ctx, __MODULE__)),
         {:ok, two_factor} <- set_up(ctx, user) do
      {:ok, %{backup_codes: BackupCodes.decrypt(config, two_factor.backup_codes)}, ctx}
    end
  end

  # A code for a challenge: right finishes it, wrong counts an attempt.
  # `check` gets the user's 2FA setup, or `nil` when there is none.
  defp answer(ctx, data, opts, check) do
    case Store.get_by(ctx, :user, id: data["user_id"]) do
      nil ->
        {:error, Challenge.expired()}

      user ->
        two_factor = two_factor(ctx, user)

        if check.(ctx, data, two_factor),
          do: finish(ctx, data, user, two_factor, opts),
          else: Challenge.failed(ctx, data, opts)
    end
  end

  defp finish(ctx, %{"kind" => "sign_in"} = data, user, two_factor, opts) do
    with {:ok, ctx} <- Sessions.create(ctx, user, data["remember_me"]) do
      ctx =
        if ctx.params.trust_device and two_factor,
          do: TrustedDevice.put(ctx, user, two_factor, opts),
          else: ctx

      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  # Turning 2FA on with a one-time code: only for the signed-in user who asked.
  defp finish(
         %Context{user: %{id: id}} = ctx,
         %{"kind" => "enable"},
         %{id: id} = user,
         _tf,
         _opts
       ),
       do: turn_on(ctx, user)

  defp finish(_ctx, _data, _user, _two_factor, _opts), do: {:error, Challenge.expired()}

  defp confirm_setup_with_totp(%Context{user: nil}, _opts), do: {:error, Challenge.expired()}

  defp confirm_setup_with_totp(%Context{user: user, params: params} = ctx, opts) do
    with {:ok, two_factor} <- set_up(ctx, user) do
      if TOTP.verify(ctx, two_factor, params.code, opts[:totp_period]),
        do: turn_on(ctx, user),
        else: {:error, Challenge.invalid_code()}
    end
  end

  defp turn_on(ctx, user) do
    with {:ok, user} <- Store.update(ctx, :user, user, %{two_factor_enabled: true}) do
      {:ok, %{status: true, user: Serializer.user(ctx, user)}, %{ctx | user: user}}
    end
  end

  # A sign-in's challenge, or a new one to turn 2FA on for the signed-in user.
  defp challenge_for_otp(ctx, opts) do
    case Challenge.take(ctx) do
      {:ok, data, ctx} ->
        {:ok, data, ctx}

      :none when is_nil(ctx.user) ->
        {:error, Challenge.expired()}

      :none ->
        {:ok, Challenge.new(ctx.user, true, "enable", opts), ctx}
    end
  end

  defp set_up(ctx, attrs, enable_now) when is_map(attrs) do
    Store.transaction(ctx, fn ->
      _replaced = Store.delete_all(ctx, :two_factor, user_id: attrs.user_id)

      with {:ok, two_factor} <- Store.insert(ctx, :two_factor, attrs),
           {:ok, _user} <- maybe_turn_on(ctx, enable_now) do
        {:ok, two_factor}
      end
    end)
  end

  defp set_up(ctx, user) do
    case two_factor(ctx, user) do
      nil -> {:error, not_enabled_error()}
      two_factor -> {:ok, two_factor}
    end
  end

  defp maybe_turn_on(%Context{user: user} = ctx, true),
    do: Store.update(ctx, :user, user, %{two_factor_enabled: true})

  defp maybe_turn_on(%Context{user: user}, false), do: {:ok, user}

  defp two_factor(ctx, user), do: Store.get_by(ctx, :two_factor, user_id: user.id)

  # The password, or with `allow_passwordless`, a fresh session for users who have none.
  defp confirm(%Context{user: user, params: params} = ctx, opts) do
    has_password =
      match?(%{password: hash} when is_binary(hash), Credentials.account(ctx, user.id))

    cond do
      is_binary(params.password) -> Credentials.check_password(ctx, user, params.password)
      has_password or not opts[:allow_passwordless] -> {:error, Error.new(:invalid_password)}
      Sessions.fresh?(ctx) -> :ok
      true -> {:error, Error.new(:session_not_fresh)}
    end
  end

  defp not_enabled(user) do
    if Map.get(user, :two_factor_enabled),
      do:
        {:error,
         Error.custom(:two_factor_already_enabled, 400, "Two-factor authentication is already on")},
      else: :ok
  end

  defp not_enabled_error,
    do: Error.custom(:two_factor_not_enabled, 400, "Two-factor authentication isn't set up")

  defp otp_sender(opts) do
    case opts[:send_otp] do
      nil -> {:error, Error.new(:feature_disabled)}
      sender -> {:ok, sender}
    end
  end

  # Encrypted, so a leaked verification store doesn't give codes away.
  defp otp_matches?(ctx, %{"otp" => encrypted, "otp_expires_at" => expires_at}, code) do
    with true <- expires_at > System.system_time(:second),
         {:ok, otp} <- Crypto.decrypt(ctx.config, @otp_purpose, encrypted) do
      Plug.Crypto.secure_compare(otp, code)
    else
      _expired_or_unreadable -> false
    end
  end

  defp otp_matches?(_ctx, _data, _code), do: false

  defp otp_code do
    <<number::40>> = :crypto.strong_rand_bytes(5)
    number |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  defp challenge_body(opts) do
    methods = ["totp"] ++ if(opts[:send_otp], do: ["otp"], else: []) ++ ["backup_code"]
    body = %{two_factor_redirect: true, two_factor_methods: methods}

    if opts[:two_factor_page],
      do: Map.put(body, :redirect_url, opts[:two_factor_page]),
      else: body
  end

  defp issuer(%Context{config: config}, opts), do: opts[:issuer] || config.app_name

  defp endpoint(name, path, function, opts) do
    Endpoint.new([name: name, method: :post, path: path, handler: {__MODULE__, function}] ++ opts)
  end
end
