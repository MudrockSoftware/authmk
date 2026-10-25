defmodule Authmk.Plugins.PhoneNumber.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            send_otp: [
              type: {:fun, 2},
              required: true,
              doc:
                "Sends a code by SMS: called with `%{phone_number: number, code: code, purpose: purpose}` (`:verification` or `:password_reset`) and the context."
            ],
            otp_length: [type: :pos_integer, default: 6],
            otp_expires_in: [type: :pos_integer, default: 300, doc: "Seconds a code lasts."],
            allowed_attempts: [
              type: :pos_integer,
              default: 3,
              doc: "Wrong guesses before a code stops working."
            ],
            validator: [
              type: {:fun, 1},
              default: &__MODULE__.e164?/1,
              doc:
                "Returns whether a phone number is acceptable. The default wants E.164, like `+14155550123`."
            ],
            require_verification: [
              type: :boolean,
              default: false,
              doc:
                "Password sign-in needs a verified phone number (a code is sent when it isn't)."
            ],
            sign_up_on_verification: [
              type: :boolean,
              default: false,
              doc: "Verifying an unknown number creates a user for it."
            ],
            temp_email: [
              type: {:fun, 1},
              default: &__MODULE__.temp_email/1,
              doc: "The email of users created by `sign_up_on_verification`, from their number."
            ],
            temp_name: [
              type: {:fun, 1},
              default: &Function.identity/1,
              doc: "The name of users created by `sign_up_on_verification`, from their number."
            ],
            min_password_length: [type: :pos_integer, default: 8],
            max_password_length: [type: :pos_integer, default: 128]
          )

  def schema, do: @schema

  @doc false
  def e164?(number), do: number =~ ~r/^\+[1-9][0-9]{6,14}$/

  @doc false
  def temp_email(number), do: String.trim_leading(number, "+") <> "@phone.invalid"
end
