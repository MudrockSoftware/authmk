defmodule Authmk.Plugins.Polar.Options do
  @moduledoc false
  # Polar's options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      server: [
        type: {:in, [:production, :sandbox]},
        default: :production,
        doc: "Polar's production API, or its sandbox."
      ]
    ]
  end
end
