defmodule Authmk.Plugins.OAuthProvider.Schema do
  @moduledoc false
  # The provider's models. Lists (redirect URIs, scopes, grant types) are
  # space-separated text: none of their values can hold a space.

  def models do
    %{
      oauth_client: [
        plural: "oauth_clients",
        fields: [
          client_id: [type: :string, required: true, unique: true, input: false],
          # SHA-256 of the secret; public clients have none.
          client_secret: [type: :string, returned: false, redact: true, input: false],
          name: [type: :string],
          uri: [type: :string],
          icon: [type: :string],
          contacts: [type: :text],
          tos_uri: [type: :string],
          policy_uri: [type: :string],
          redirect_uris: [type: :text],
          post_logout_redirect_uris: [type: :text],
          scopes: [type: :text],
          grant_types: [type: :text, required: true],
          response_types: [type: :text],
          token_endpoint_auth_method: [type: :string, required: true],
          application_type: [type: :string, required: true, default: "web"],
          require_pkce: [type: :boolean, required: true, default: true],
          # Every token request must carry a DPoP proof (RFC 9449).
          dpop_bound_access_tokens: [type: :boolean, required: true, default: false],
          skip_consent: [type: :boolean, required: true, default: false, input: false],
          disabled: [type: :boolean, required: true, default: false, input: false],
          subject_type: [type: :string],
          jwks: [type: :text],
          jwks_uri: [type: :string],
          # Told by back-channel logout (OpenID Connect) when a session ends.
          backchannel_logout_uri: [type: :string],
          software_id: [type: :string],
          software_version: [type: :string],
          software_statement: [type: :text],
          user_id: [references: :user, on_delete: :delete_all, index: true, input: false],
          # An organization's id, or your own grouping. Without a foreign key.
          reference_id: [type: :string, index: true, input: false],
          # JSON
          metadata: [type: :text],
          # For clients from client ID metadata documents: when to fetch again.
          metadata_document_expires_at: [type: :datetime, input: false]
        ]
      ],
      oauth_access_token: [
        plural: "oauth_access_tokens",
        fields: [
          # SHA-256 of the token.
          token: [type: :string, required: true, unique: true, returned: false, redact: true],
          oauth_client_id: [references: :oauth_client, on_delete: :delete_all, index: true],
          user_id: [references: :user, on_delete: :delete_all, index: true],
          # Sessions may live in secondary storage: no foreign key.
          session_id: [type: :string, index: true],
          refresh_token_id: [type: :string, index: true],
          scopes: [type: :text],
          resource: [type: :string],
          reference_id: [type: :string],
          # The thumbprint of the key a DPoP-bound token is tied to.
          dpop_jkt: [type: :string],
          expires_at: [type: :datetime, required: true]
        ]
      ],
      oauth_refresh_token: [
        plural: "oauth_refresh_tokens",
        fields: [
          token: [type: :string, required: true, unique: true, returned: false, redact: true],
          oauth_client_id: [references: :oauth_client, on_delete: :delete_all, index: true],
          user_id: [references: :user, on_delete: :delete_all, index: true],
          session_id: [type: :string, index: true],
          # The first token of a rotation chain: reusing an old one ends all.
          family_id: [type: :string, index: true],
          scopes: [type: :text],
          resource: [type: :string],
          reference_id: [type: :string],
          auth_time: [type: :datetime],
          dpop_jkt: [type: :string],
          expires_at: [type: :datetime, required: true],
          revoked_at: [type: :datetime]
        ]
      ],
      # Client assertions already used (their jti), until they expire: the
      # unique key makes a replay fail on insert, on every database.
      oauth_assertion: [
        plural: "oauth_assertions",
        fields: [
          key: [type: :string, required: true, unique: true],
          expires_at: [type: :datetime, required: true, index: true]
        ]
      ],
      oauth_consent: [
        plural: "oauth_consents",
        fields: [
          oauth_client_id: [references: :oauth_client, on_delete: :delete_all, index: true],
          user_id: [references: :user, on_delete: :delete_all, index: true],
          scopes: [type: :text, required: true],
          reference_id: [type: :string]
        ]
      ]
    }
  end
end
