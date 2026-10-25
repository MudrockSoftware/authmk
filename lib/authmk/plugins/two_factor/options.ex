defmodule Authmk.Plugins.TwoFactor.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            issuer: [
              type: :string,
              doc: "The name authenticator apps show. Defaults to the `app_name` option."
            ],
            totp_period: [
              type: :pos_integer,
              default: 30,
              doc: "Seconds each authenticator code lasts."
            ],
            skip_verification_on_enable: [
              type: :boolean,
              default: false,
              doc: "Turn 2FA on at once, without a first code from the authenticator app."
            ],
            allow_passwordless: [
              type: :boolean,
              default: false,
              doc:
                "Users without a password manage 2FA with a fresh session instead. Others always confirm with their password."
            ],
            send_otp: [
              type: {:fun, 2},
              doc:
                "Sends a one-time code by email or SMS: called with `%{user: user, otp: code}` and the context. Without it, one-time codes are off."
            ],
            otp_expires_in: [
              type: :pos_integer,
              default: 300,
              doc: "Seconds a one-time code lasts."
            ],
            backup_code_count: [type: :pos_integer, default: 10],
            backup_code_length: [
              type: {:in, [8, 10, 12, 16]},
              default: 10,
              doc: "Characters per backup code, shown in two halves."
            ],
            challenge_expires_in: [
              type: :pos_integer,
              default: 600,
              doc: "Seconds a signed-in-with-password user has to enter the second factor."
            ],
            max_attempts: [
              type: :pos_integer,
              default: 5,
              doc: "Wrong codes allowed before the user must sign in again."
            ],
            trust_device_days: [
              type: :pos_integer,
              default: 30,
              doc: "Days a trusted device skips 2FA (refreshed on every sign-in)."
            ],
            two_factor_page: [
              type: :string,
              doc:
                "Where sign-ins that end in a redirect (social sign-in) send users for the second step."
            ]
          )

  def schema, do: @schema
end
