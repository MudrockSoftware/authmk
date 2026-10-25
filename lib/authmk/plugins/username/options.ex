defmodule Authmk.Plugins.Username.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            min_length: [type: :pos_integer, default: 3],
            max_length: [type: :pos_integer, default: 30],
            validator: [
              type: {:fun, 1},
              default: &__MODULE__.valid_username?/1,
              doc:
                "Returns whether a normalized username is allowed. The default allows letters, numbers, dots and underscores."
            ],
            normalizer: [
              type: {:fun, 1},
              default: &String.downcase/1,
              doc: "Turns a typed username into the stored one. Sign-in normalizes the same way."
            ],
            display_username_validator: [
              type: {:fun, 1},
              default: &__MODULE__.any?/1,
              doc: "Returns whether a display username is allowed."
            ],
            display_username_normalizer: [
              type: {:fun, 1},
              default: &Function.identity/1
            ],
            disable_availability_check: [
              type: :boolean,
              default: false,
              doc: "Turn off `POST /is-username-available`."
            ],
            immutable: [
              type: :boolean,
              default: false,
              doc: "Users can't change a username once they have one."
            ]
          )

  def schema, do: @schema

  @doc false
  def valid_username?(username), do: username =~ ~r/^[a-zA-Z0-9_.]+$/

  @doc false
  def any?(_display_username), do: true
end
