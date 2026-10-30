defmodule Authmk.Payments.Schema do
  @moduledoc false
  # The tables every payment plugin shares (an app bills through one
  # provider at a time): who the provider knows as a customer, and their
  # subscriptions. A reference is what's billed: a user, or an organization.

  def models do
    %{
      billing_customer: [
        plural: "billing_customers",
        fields: [
          provider: [type: :string, required: true, input: false],
          # A user's or an organization's id. Without foreign keys: either.
          reference_id: [type: :string, required: true, input: false],
          reference_type: [type: :string, required: true, default: "user", input: false],
          customer_id: [type: :string, required: true, input: false]
        ],
        # One customer per reference and provider, and the other way round.
        indexes: [
          [columns: [:provider, :customer_id], unique: true],
          [columns: [:provider, :reference_type, :reference_id], unique: true]
        ]
      ],
      subscription: [
        plural: "subscriptions",
        fields: [
          provider: [type: :string, required: true, input: false],
          reference_id: [type: :string, required: true, index: true, input: false],
          reference_type: [type: :string, required: true, default: "user", input: false],
          customer_id: [type: :string, input: false],
          provider_subscription_id: [type: :string, required: true, input: false],
          # The plan's name from config, and the provider's price or product id.
          plan: [type: :string, input: false],
          price_id: [type: :string, input: false],
          # active, trialing, past_due, unpaid, paused, incomplete, canceled
          status: [type: :string, required: true, input: false],
          period_start: [type: :datetime, input: false],
          period_end: [type: :datetime, input: false],
          cancel_at_period_end: [type: :boolean, required: true, default: false, input: false],
          canceled_at: [type: :datetime, input: false],
          trial_start: [type: :datetime, input: false],
          trial_end: [type: :datetime, input: false],
          seats: [type: :integer, input: false]
        ],
        indexes: [[columns: [:provider, :provider_subscription_id], unique: true]]
      ]
    }
  end
end
