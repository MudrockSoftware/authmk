defmodule Authmk.Plugins.Chargebee.Options do
  @moduledoc false
  # Chargebee's options, next to Authmk.Payments.Options' shared ones.

  def own do
    [
      site: [
        type: :string,
        required: true,
        doc:
          "Your Chargebee site: `acme` for `acme.chargebee.com` (`acme-test` for the test site)."
      ]
    ]
  end
end
