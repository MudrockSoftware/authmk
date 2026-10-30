defmodule Authmk.Plugins.DodoPayments.Options do
  @moduledoc false
  # Dodo Payments' options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      environment: [
        type: {:in, [:live, :test]},
        default: :live,
        doc: "Dodo's live API, or its test mode (`dodo_test_` keys)."
      ]
    ]
  end
end
