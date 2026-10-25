defmodule Authmk.Plugins.MagicLink.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            send_magic_link: [
              type: {:fun, 2},
              required: true,
              doc:
                "Sends the link: called with `%{email: email, url: url, token: token}` and the context."
            ],
            expires_in: [type: :pos_integer, default: 300, doc: "Seconds a link works."],
            disable_sign_up: [
              type: :boolean,
              default: false,
              doc: "Links only sign in existing users; unknown emails get no link."
            ],
            generate_token: [
              type: {:fun, 1},
              doc:
                "Makes the token from the email, instead of 32 random bytes. It must be unguessable. Tokens are always stored hashed."
            ]
          )

  def schema, do: @schema
end
