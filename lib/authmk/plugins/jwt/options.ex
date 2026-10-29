defmodule Authmk.Plugins.JWT.Options do
  @moduledoc false

  @algorithms ~w(EdDSA ES256 ES384 ES512 RS256 RS384 RS512 PS256 PS384 PS512)

  @schema NimbleOptions.new!(
            algorithm: [type: {:in, @algorithms}, default: "EdDSA", doc: "The signing algorithm."],
            expires_in: [type: :pos_integer, default: 900, doc: "Seconds a token lasts."],
            issuer: [type: :string, doc: "The `iss` claim. Defaults to the base URL."],
            audience: [
              type: {:or, [:string, {:list, :string}]},
              doc: "The `aud` claim. Defaults to the base URL."
            ],
            define_payload: [
              type: {:fun, 1},
              doc:
                "Builds the token's claims from `%{user: user, session: session}`. Defaults to the user's public fields."
            ],
            get_subject: [
              type: {:fun, 1},
              doc:
                "Gives the `sub` claim from `%{user: user, session: session}`. Defaults to the user's id."
            ],
            jwks_path: [type: :string, default: "/jwks", doc: "Where the public keys are served."],
            remote_jwks_url: [
              type: :string,
              doc:
                "Keys live elsewhere: no keys are made or served here, `sign` signs, and `verify/2` fetches this JWKS."
            ],
            sign: [
              type: {:fun, 2},
              doc:
                "Signs claims yourself (like with a KMS): called with the claims and the context, returns the token."
            ],
            encrypt_private_keys: [
              type: :boolean,
              default: true,
              doc: "Store private keys encrypted with the secret."
            ],
            rotation_interval: [
              type: :pos_integer,
              doc: "Seconds before a new key takes over. Keys don't rotate without it."
            ],
            grace_period: [
              type: :pos_integer,
              default: 30 * 86_400,
              doc:
                "Seconds a rotated-out key stays in the JWKS, so tokens it signed still verify."
            ],
            key_store: [
              type: :atom,
              default: Authmk.Plugins.JWT.DatabaseKeyStore,
              doc: "Where keys are kept: a module implementing `Authmk.Plugins.JWT.KeyStore`."
            ]
          )

  def schema, do: @schema
  def algorithms, do: @algorithms
end
