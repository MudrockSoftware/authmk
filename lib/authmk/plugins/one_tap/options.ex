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
            ]
          )

  def schema, do: @schema
end
