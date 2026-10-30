defmodule Authmk.Payments.Options do
  @moduledoc false
  # Options every payment plugin takes, plus its own.

  @hooks [
    :on_subscription_created,
    :on_subscription_updated,
    :on_subscription_canceled,
    :on_trial_started,
    :on_trial_ended
  ]

  def hooks, do: @hooks

  def schema(own) do
    hook_options =
      for hook <- @hooks do
        {hook,
         [type: {:fun, 2}, doc: "`fn subscription, ctx -> ... end`. See `Authmk.Payments`."]}
      end

    NimbleOptions.new!(
      [
        api_key: [
          type: {:or, [:string, {:fun, 0}]},
          required: true,
          doc: "The provider's secret API key, or a function returning it (runtime config)."
        ],
        webhook_secret: [
          type: {:or, [:string, {:fun, 0}]},
          required: true,
          doc: "The webhook signing secret, or a function returning it."
        ],
        plans: [
          type: {:list, :keyword_list},
          default: [],
          doc:
            "`[name: \"pro\", id: \"<provider's price or product id>\", annual_id: ..., trial_days: 14, no_trial_id: ..., limits: %{projects: 10}]`. Checkout takes a plan's name; webhooks map ids back to names. `no_trial_id`: for providers whose trials are set on the product, the same plan without a trial, used once the user or organization had theirs."
        ],
        create_customer_on_sign_up: [
          type: :boolean,
          default: false,
          doc: "Create the provider's customer for each new user, in the background."
        ],
        organizations: [
          type: :boolean,
          default: false,
          doc:
            "Let organizations subscribe (`reference_id` in requests), with `Authmk.Plugins.Organization`. Their owners and admins manage billing, unless `authorize_reference` says otherwise."
        ],
        authorize_reference: [
          type: {:fun, 4},
          doc:
            "`fn user, reference_id, action, ctx -> boolean end`, for organizations' billing (`:checkout`, `:list`, `:portal`, `:cancel`)."
        ]
      ] ++ hook_options ++ own
    )
  end

  @doc "A secret from config: as given, or from its function."
  def secret(value) when is_function(value, 0), do: value.()
  def secret(value), do: value
end
