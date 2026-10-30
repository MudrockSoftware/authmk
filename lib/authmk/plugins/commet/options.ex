defmodule Authmk.Plugins.Commet.Options do
  @moduledoc false
  # Commet's options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      api_version: [
        type: :string,
        default: "2026-08-27",
        doc: "Commet's API version, sent with every request (`Commet-Version`)."
      ]
    ]
  end
end
