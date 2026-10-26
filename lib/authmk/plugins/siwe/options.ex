defmodule Authmk.Plugins.SIWE.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            domain: [
              type: :string,
              doc:
                "The domain messages must be for, like `app.example.com`. Defaults to the base URL's host (and port)."
            ],
            anonymous: [
              type: :boolean,
              default: true,
              doc:
                "Wallets sign up without an email (they get a placeholder). Otherwise new wallets must send an `email`."
            ],
            email_domain: [
              type: :string,
              doc: "Domain of placeholder emails. Defaults to `domain`."
            ],
            ens_lookup: [
              type: {:fun, 1},
              doc:
                "Looks up a new wallet's ENS name and avatar: called with the address, returns `%{name: name, avatar: url}` or `nil`."
            ],
            nonce_expires_in: [type: :pos_integer, default: 900, doc: "Seconds."]
          )

  def schema, do: @schema
end
