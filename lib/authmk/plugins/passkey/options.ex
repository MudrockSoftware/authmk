defmodule Authmk.Plugins.Passkey.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            origin: [
              type: {:or, [:string, {:list, :string}]},
              doc:
                "The origin(s) of the pages that call WebAuthn, like `https://app.example.com`. Defaults to the base URL's."
            ],
            rp_id: [
              type: :string,
              doc:
                "The relying party id: the domain passkeys belong to. Defaults to the origin's host."
            ],
            rp_name: [type: :string, doc: "The name authenticators show. Defaults to `app_name`."],
            user_verification: [
              type: {:in, ["required", "preferred", "discouraged"]},
              default: "preferred",
              doc:
                "Whether authenticators must verify the user (PIN, biometrics). Passkeys that did count as two factors."
            ],
            challenge_expires_in: [type: :pos_integer, default: 300, doc: "Seconds."],
            sign_up: [
              type: :boolean,
              default: false,
              doc:
                "Visitors without an account may register a passkey with an `email` and `name`, creating their account."
            ],
            registration_extensions: [
              type: {:map, :string, :any},
              default: %{},
              doc: "WebAuthn extension inputs for registration, like `%{\"credProps\" => true}`."
            ],
            authentication_extensions: [
              type: {:map, :string, :any},
              default: %{},
              doc: "WebAuthn extension inputs for sign-in."
            ],
            authenticator_names: [
              type: {:map, :string, :string},
              default: %{},
              doc:
                "More AAGUID => name entries for naming passkeys after their authenticator (see `Authmk.Plugins.Passkey.Authenticators`)."
            ]
          )

  def schema, do: @schema
end
