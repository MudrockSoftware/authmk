defmodule Authmk.Schema.Core do
  @moduledoc """
  The four core models every authmk app has: `user`, `session`, `account` and
  `verification`. Plugins and user config extend these.

  Only `user.name` and `user.image` accept request input. Every other core
  field is set by authmk itself.
  """

  @doc "Core model specs, in the same format plugins use."
  @spec models() :: %{atom() => keyword()}
  def models do
    %{
      user: [
        plural: "users",
        fields: [
          name: [type: :string, required: true],
          email: [type: :string, required: true, unique: true, input: false],
          email_verified: [type: :boolean, required: true, default: false, input: false],
          image: [type: :text]
        ]
      ],
      session: [
        plural: "sessions",
        fields: [
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          # SHA-256 hash of the session token. The token itself only lives in the cookie.
          token: [
            type: :string,
            required: true,
            unique: true,
            returned: false,
            redact: true,
            input: false
          ],
          expires_at: [type: :datetime, required: true, input: false],
          ip_address: [type: :string, input: false],
          user_agent: [type: :text, input: false]
        ]
      ],
      account: [
        plural: "accounts",
        fields: [
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          account_id: [type: :string, required: true, input: false],
          provider_id: [type: :string, required: true, input: false],
          access_token: [type: :text, returned: false, redact: true, input: false],
          refresh_token: [type: :text, returned: false, redact: true, input: false],
          id_token: [type: :text, returned: false, redact: true, input: false],
          access_token_expires_at: [type: :datetime, input: false],
          refresh_token_expires_at: [type: :datetime, input: false],
          scope: [type: :text, input: false],
          # Password hash, for accounts with provider_id "credential".
          password: [type: :string, returned: false, redact: true, input: false]
        ],
        indexes: [[columns: [:provider_id, :account_id], unique: true]]
      ],
      verification: [
        plural: "verifications",
        fields: [
          # "<purpose>:<SHA-256 of the token>"
          identifier: [type: :string, required: true, index: true, input: false],
          value: [type: :text, required: true, input: false],
          expires_at: [type: :datetime, required: true, input: false]
        ]
      ]
    }
  end
end
