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
          type: {:list, {:custom, __MODULE__, :plan, []}},
          default: [],
          doc:
            "`[name: \"pro\", id: \"<provider's price or product id>\", annual_id: ..., trial_days: 14, no_trial_id: ..., limits: %{projects: 10}, amount: 2000, annual_amount: 20_000, currency: \"usd\"]`. Checkout takes a plan's name; webhooks map ids back to names. `no_trial_id`: for providers whose trials are set on the product, the same plan without a trial, used once the user or organization had theirs. `amount` (the monthly price of `id` and `no_trial_id`), `annual_amount` (the yearly price of `annual_id`) and `currency` (an ISO 4217 code) are optional: non-negative integers in the currency's minor unit (cents), for `Authmk.Payments.monthly_amount/2`. They don't set what the provider charges."
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

  @doc false
  # One of `plans`: a keyword list whose prices, when given, are whole
  # amounts in minor units with a currency. The currency is kept lowercase,
  # so amounts in "USD" and "usd" add up together.
  def plan(plan) do
    if Keyword.keyword?(plan),
      do: prices(plan),
      else: {:error, "expected each plan to be a keyword list, got: #{inspect(plan)}"}
  end

  defp prices(plan) do
    with :ok <- amount(plan, :amount),
         :ok <- amount(plan, :annual_amount),
         :ok <- annual_amount_has_id(plan),
         {:ok, currency} <- currency(plan) do
      {:ok, if(currency, do: Keyword.put(plan, :currency, currency), else: plan)}
    end
  end

  defp amount(plan, key) do
    case plan[key] do
      nil ->
        :ok

      value when is_integer(value) and value >= 0 ->
        :ok

      value ->
        {:error,
         "plan #{inspect(plan[:name])}: #{key} must be a non-negative integer in minor units (cents), got: #{inspect(value)}"}
    end
  end

  defp annual_amount_has_id(plan) do
    if is_nil(plan[:annual_amount]) or not is_nil(plan[:annual_id]),
      do: :ok,
      else:
        {:error,
         "plan #{inspect(plan[:name])}: annual_amount is the price of annual_id, which is missing"}
  end

  defp currency(plan) do
    priced = not is_nil(plan[:amount]) or not is_nil(plan[:annual_amount])

    case plan[:currency] do
      nil when priced ->
        {:error,
         "plan #{inspect(plan[:name])}: amount and annual_amount need a currency, like \"usd\""}

      nil ->
        {:ok, nil}

      code when is_binary(code) ->
        if Regex.match?(~r/\A[A-Za-z]{3}\z/, code),
          do: {:ok, String.downcase(code)},
          else: {:error, currency_error(plan, code)}

      code ->
        {:error, currency_error(plan, code)}
    end
  end

  defp currency_error(plan, code),
    do:
      "plan #{inspect(plan[:name])}: currency must be an ISO 4217 code like \"usd\", got: #{inspect(code)}"

  @doc "A secret from config: as given, or from its function."
  def secret(value) when is_function(value, 0), do: value.()
  def secret(value), do: value
end
