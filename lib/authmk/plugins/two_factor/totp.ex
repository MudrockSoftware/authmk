defmodule Authmk.Plugins.TwoFactor.TOTP do
  @moduledoc false
  # Authenticator app codes (RFC 6238). The secret is stored encrypted.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{Crypto, Store}

  @purpose "two-factor-totp"

  def new_secret, do: NimbleTOTP.secret()

  def encrypt(config, secret), do: Crypto.encrypt(config, @purpose, secret)

  def decrypt(config, encrypted) do
    {:ok, secret} = Crypto.decrypt(config, @purpose, encrypted)
    secret
  end

  def uri(secret, user, issuer, period) do
    NimbleTOTP.otpauth_uri("#{issuer}:#{user.email}", secret, issuer: issuer, period: period)
  end

  @doc """
  Checks `code` against the secret, for this period or the one before (clock
  drift), and records its period so the code can't be used again. The record
  is a conditional update, so two requests with one code can't both pass.
  """
  def verify(ctx, two_factor, code, period) do
    secret = decrypt(ctx.config, two_factor.secret)
    now = System.os_time(:second)

    case Enum.find(
           [now, now - period],
           &NimbleTOTP.valid?(secret, code, time: &1, period: period)
         ) do
      nil -> false
      time -> use_step(ctx, two_factor, Integer.floor_div(time, period))
    end
  end

  defp use_step(ctx, two_factor, step) do
    id = two_factor.id

    query =
      from(t in Store.module(ctx, :two_factor),
        where: t.id == ^id and (is_nil(t.totp_last_step) or t.totp_last_step < ^step)
      )

    Store.update_all(ctx, :two_factor, query, set: [totp_last_step: step]) == 1
  end
end
