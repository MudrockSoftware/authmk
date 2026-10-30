defmodule Authmk.Plugins.DeviceAuthorization.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            expires_in: [type: :pos_integer, default: 1800, doc: "Seconds the codes last."],
            interval: [type: :pos_integer, default: 5, doc: "Seconds between polls."],
            user_code_length: [type: :pos_integer, default: 8],
            verification_uri: [
              type: :string,
              doc:
                "Your page where users enter the code. Defaults to `/device` on the base URL's host."
            ],
            validate_client: [
              type: {:fun, 1},
              doc:
                "Returns whether a `client_id` may ask for codes. Without it: with `Authmk.Plugins.OAuthProvider`, its clients that have the device code grant; otherwise any."
            ],
            generate_device_code: [
              type: {:fun, 0},
              doc: "Makes device codes; must be unguessable."
            ],
            generate_user_code: [type: {:fun, 0}, doc: "Makes user codes."],
            token_type: [
              type: {:in, [:session, :jwt]},
              default: :session,
              doc: "A session token, or a JWT (with `Authmk.Plugins.JWT`)."
            ]
          )

  def schema, do: @schema
end
