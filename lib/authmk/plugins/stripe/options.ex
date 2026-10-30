defmodule Authmk.Plugins.Stripe.Options do
  @moduledoc false
  # Stripe's options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      api_version: [
        type: :string,
        default: "2026-10-28.endive",
        doc: "Stripe's API version, sent with every request."
      ],
      automatic_tax: [
        type: :boolean,
        default: false,
        doc:
          "Stripe Tax at checkout: tax computed from the customer's address, which Checkout asks for and saves."
      ],
      tax_id_collection: [
        type: :boolean,
        default: false,
        doc: "Let business customers give a tax ID at checkout."
      ],
      allow_promotion_codes: [type: :boolean, default: false, doc: "Show a promotion code field."]
    ]
  end
end
