defmodule Authmk.Plugins.HaveIBeenPwned do
  @moduledoc """
  Refuses passwords that appear in known data breaches, checked against
  Have I Been Pwned's Pwned Passwords.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.HaveIBeenPwned], ...

  Only the first five characters of the password's SHA-1 leave your server
  (k-anonymity), with padded answers so their size reveals nothing.

  Every endpoint that sets a password is checked: sign-up, password change
  and reset (email, phone number and email OTP), and the admin's. Check your
  own password flows with `check/2`.

  When the service can't be reached, the password is refused
  (`password_check_unavailable`): a breached password shouldn't get in
  during an outage. Set `fail_open: true` to let it through instead.

  ## Options

    * `:message` - what users see for a breached password
    * `:fail_open` - accept passwords when the check can't be done (default `false`)
    * `:endpoints` - endpoint names to check, with the param holding the
      password (default: every core and plugin endpoint that sets one)
  """

  use Authmk.Plugin

  alias Authmk.{Context, Error}
  alias Authmk.OAuth.HTTP

  @range_url "https://api.pwnedpasswords.com/range/"

  @default_endpoints [
    sign_up_email: "password",
    change_password: "new_password",
    reset_password: "new_password",
    reset_password_phone_number: "new_password",
    reset_password_email_otp: "password",
    admin_create_user: "password",
    admin_set_user_password: "new_password"
  ]

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      message: [
        type: :string,
        default: "This password appeared in a data breach. Choose another one."
      ],
      fail_open: [type: :boolean, default: false],
      endpoints: [type: :keyword_list, default: @default_endpoints]
    )
  end

  @impl true
  def before_endpoint(endpoint, %Context{raw_params: params} = ctx) do
    opts = opts(ctx)

    with field when is_binary(field) <- opts[:endpoints][endpoint],
         password when is_binary(password) <- params[field] do
      case check_password(ctx, password, opts) do
        :ok -> {:cont, ctx}
        {:error, error} -> {:halt, error}
      end
    else
      _not_checked_here -> {:cont, ctx}
    end
  end

  @doc """
  Checks a password, for your own flows: `:ok`, or an error when it's been
  breached (or the check couldn't be done, unless `fail_open`).
  """
  @spec check(module(), String.t()) :: :ok | {:error, Error.t()}
  def check(auth, password) do
    ctx = Context.new(auth.config())
    check_password(ctx, password, opts(ctx))
  end

  defp check_password(ctx, password, opts) do
    hash = :sha |> :crypto.hash(password) |> Base.encode16()
    {prefix, suffix} = String.split_at(hash, 5)

    case HTTP.get(ctx, @range_url <> prefix, [{"add-padding", "true"}]) do
      {:ok, 200, body} when is_binary(body) ->
        if breached?(body, suffix),
          do: {:error, Error.custom(:password_compromised, 422, opts[:message])},
          else: :ok

      _unavailable ->
        if opts[:fail_open], do: :ok, else: {:error, unavailable()}
    end
  end

  # Lines are "SUFFIX:COUNT"; padding lines have a count of 0.
  defp breached?(body, suffix) do
    body
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.any?(fn line ->
      case String.split(line, ":") do
        [^suffix, count] -> String.trim(count) != "0"
        _other -> false
      end
    end)
  end

  defp unavailable,
    do:
      Error.custom(
        :password_check_unavailable,
        503,
        "The password couldn't be checked; try again"
      )

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
