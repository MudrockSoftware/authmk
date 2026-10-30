defmodule Authmk.Plugins.OneTap.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            redirect_url: [
              type: :string,
              default: "/",
              doc: "Where redirect mode sends signed-in users."
            ],
            error_url: [
              type: :string,
              doc:
                "Where redirect mode sends errors, as `?error=<code>`. Defaults to the error page."
            ],
            require_nonce: [
              type: :boolean,
              default: false,
              doc:
                "Credentials must carry an unused nonce from `POST /one-tap/nonce`, so a leaked one can't be replayed. See Nonces."
            ],
            nonce_expires_in: [type: :pos_integer, default: 600, doc: "Seconds."]
          )

  def schema, do: @schema
end
