defmodule Authmk.Plugins.EmailPassword.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            disable_sign_up: [type: :boolean, default: false],
            require_email_verification: [
              type: :boolean,
              default: false,
              doc: "Users must verify their email before they can sign in."
            ],
            auto_sign_in: [
              type: :boolean,
              default: true,
              doc: "Sign users in right after sign-up."
            ],
            min_password_length: [type: :pos_integer, default: 8],
            max_password_length: [type: :pos_integer, default: 128],
            reset_password_token_expires_in: [type: :pos_integer, default: 3600, doc: "Seconds."],
            reset_password_page: [
              type: :string,
              doc:
                "Your page where users choose a new password (a path or a trusted URL), opened with `?token=...`. Reset links requested without `redirect_to` go there."
            ],
            revoke_sessions_on_password_reset: [type: :boolean, default: true]
          )

  def schema, do: @schema
end
