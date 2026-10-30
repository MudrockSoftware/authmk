defmodule Authmk.Plugins.Creem.Options do
  @moduledoc false
  # Creem's options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      environment: [
        type: {:in, [:production, :test]},
        default: :production,
        doc: "Creem's production API, or its test mode."
      ]
    ]
  end
end
