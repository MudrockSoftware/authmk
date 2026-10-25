defmodule Authmk.Plugins.EmailOTP.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            send_otp: [
              type: {:fun, 2},
              required: true,
              doc:
                "Sends a code by email: called with `%{email: email, otp: code, type: type}` (`:sign_in`, `:email_verification`, `:forget_password` or `:change_email`) and the context."
            ],
            otp_length: [type: :pos_integer, default: 6],
            expires_in: [type: :pos_integer, default: 300, doc: "Seconds a code lasts."],
            allowed_attempts: [
              type: :pos_integer,
              default: 3,
              doc: "Wrong guesses before a code stops working."
            ],
            disable_sign_up: [
              type: :boolean,
              default: false,
              doc: "Codes only sign in existing users."
            ],
            override_default_email_verification: [
              type: :boolean,
              default: false,
              doc:
                "Email verification sends a code instead of a link, wherever authmk would send the link."
            ],
            min_password_length: [type: :pos_integer, default: 8],
            max_password_length: [type: :pos_integer, default: 128]
          )

  def schema, do: @schema
end
