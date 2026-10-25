defmodule Authmk.Schema.Core do
  @moduledoc """
  The four core models every authmk app has: `user`, `session`, `account` and
  `verification`. Plugins and user config extend these.
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
          user_id: [references: :user, on_delete: :delete_all, required: true, index: true],
          # SHA-256 hash of the session token. The token itself only lives in the cookie.
          token: [type: :string, required: true, unique: true, returned: false, redact: true],
          expires_at: [type: :datetime, required: true],
          ip_address: [type: :string],
          user_agent: [type: :text]
        ]
      ],
      account: [
        plural: "accounts",
        fields: [
          user_id: [references: :user, on_delete: :delete_all, required: true, index: true],
          account_id: [type: :string, required: true],
          provider_id: [type: :string, required: true],
          access_token: [type: :text, returned: false, redact: true],
          refresh_token: [type: :text, returned: false, redact: true],
          id_token: [type: :text, returned: false, redact: true],
          access_token_expires_at: [type: :datetime],
          refresh_token_expires_at: [type: :datetime],
          scope: [type: :text],
          # Password hash, for accounts with provider_id "credential".
          password: [type: :string, returned: false, redact: true]
        ],
        indexes: [[columns: [:provider_id, :account_id], unique: true]]
      ],
      verification: [
        plural: "verifications",
        fields: [
          # "<purpose>:<SHA-256 of the token>"
          identifier: [type: :string, required: true, index: true],
          value: [type: :text, required: true],
          expires_at: [type: :datetime, required: true]
        ]
      ]
    }
  end
end
