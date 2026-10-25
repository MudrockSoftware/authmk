defmodule Authmk.OAuth.Providers.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            client_id: [type: :string, required: true],
            client_secret: [type: :string],
            provider: [
              type: :atom,
              doc:
                "Your `Authmk.OAuth.Provider` module, or a built-in provider's name (like `:generic`)."
            ],
            scopes: [
              type: {:list, :string},
              default: [],
              doc: "Scopes to request on top of the defaults."
            ],
            disable_default_scopes: [type: :boolean, default: false],
            redirect_uri: [
              type: :string,
              doc: "Defaults to `<base_url><base_path>/callback/<provider>`."
            ],
            prompt: [type: :string, doc: ~s(Like "select_account" or "consent".)],
            access_type: [type: :string, doc: ~s(Google: "offline" for a refresh token.)],
            response_mode: [type: :string],
            authorize_params: [
              type: {:map, :string, :string},
              default: %{},
              doc: "Extra authorization URL params."
            ],
            authorize_url: [type: :string, doc: "Overrides the provider's."],
            token_url: [type: :string, doc: "Overrides the provider's."],
            userinfo_url: [type: :string, doc: "Overrides the provider's."],
            issuer: [type: {:or, [:string, {:list, :string}]}, doc: "Overrides the provider's."],
            jwks_url: [type: :string, doc: "Overrides the provider's."],
            discovery_url: [
              type: :string,
              doc: "An OpenID Connect discovery document that fills in the other URLs."
            ],
            end_session_url: [
              type: :string,
              doc: "The provider's logout endpoint, for `POST /sign-out/social`."
            ],
            idp_initiated_login: [
              type: :boolean,
              default: false,
              doc: "Allow sign-in started by the provider (`GET /sign-in/initiate/:provider`)."
            ],
            disable_sign_up: [
              type: :boolean,
              default: false,
              doc: "Only existing users may sign in."
            ],
            disable_implicit_sign_up: [
              type: :boolean,
              default: false,
              doc: "New users only with `request_sign_up: true` on `POST /sign-in/social`."
            ],
            disable_id_token_sign_in: [type: :boolean, default: false],
            token_auth: [
              type: {:in, [:post, :basic, :none]},
              doc: "How the token endpoint authenticates the app. `:none` for public clients."
            ],
            audience: [
              type: {:list, :string},
              default: [],
              doc:
                "More accepted ID token audiences besides `client_id`, like native app bundle ids."
            ],
            access_token_expires_in: [
              type: :pos_integer,
              doc: "Access token lifetime in seconds, for providers that don't say."
            ],
            require_email_verification: [
              type: :boolean,
              default: false,
              doc: "Refuse sign-in unless the provider says the email is verified."
            ],
            override_user_info_on_sign_in: [
              type: :boolean,
              default: false,
              doc: "Update the user's name and image from the provider on every sign-in."
            ]
          )

  def schema, do: @schema
end
