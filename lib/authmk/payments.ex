defmodule Authmk.Payments do
  @moduledoc """
  Subscriptions, whichever payment plugin bills them:
  `Authmk.Plugins.Stripe`, `Authmk.Plugins.Polar`, `Authmk.Plugins.Chargebee`,
  `Authmk.Plugins.Creem`, `Authmk.Plugins.DodoPayments` or
  `Authmk.Plugins.Commet` (one per app).

  Each adds the same endpoints:

  | Method | Path | Session |
  |---|---|---|
  | POST | `/billing/checkout` | required |
  | GET | `/billing/subscriptions` | required |
  | POST | `/billing/portal` | required |
  | POST | `/billing/cancel` | required |
  | POST | `/billing/webhook` | none (signed by the provider) |

  `POST /billing/checkout` takes a plan's `name` from `plans`, `annual`,
  `seats`, `success_url` and `cancel_url` (relative paths or trusted
  origins), and answers with the provider's checkout URL. A plan's
  `trial_days` are given once per user or organization, whatever the plan:
  a trial can't be had twice by cancelling and subscribing again.

  Subscriptions are stored as the provider's signed webhooks report them
  (point the provider at `<base URL>/billing/webhook`). Webhooks are
  checked against the exact body sent, so Phoenix apps add
  `Authmk.Plug.RawBody` to their endpoint's `Plug.Parsers`. Each change
  calls the plugin's hooks, `fn subscription, ctx -> ... end`:
  `on_subscription_created`, `on_subscription_updated`,
  `on_subscription_canceled` (now, or at period end), `on_trial_started`
  and `on_trial_ended`.

  With `organizations: true`, requests with `reference_id` bill an
  organization, managed by its owners and admins (or whoever
  `authorize_reference` allows).

  A reference that already has a subscription (active, trialing, or
  waiting for a payment) can't check out again: plans are changed (in the
  provider's portal, or with `change_plan/4`) and payments fixed in the
  portal, so nobody pays twice.

  From your code, check what a user or organization has with the functions
  below. They take a user's id, or `{:organization, id}`:

      Authmk.Payments.allowed?(MyApp.Auth, user.id, :projects, 3)
      Authmk.Payments.plan(MyApp.Auth, {:organization, org.id})

  ## Managing subscriptions from the server

  An admin page, or your own back office, can change plans, cancel and
  resume through the configured provider, by the subscription's id in your
  database. Nothing checks who's asking: authorize the caller first.

      Authmk.Payments.change_plan(MyApp.Auth, subscription.id, "team", annual: true)
      Authmk.Payments.cancel(MyApp.Auth, subscription.id)
      Authmk.Payments.resume(MyApp.Auth, subscription.id)

  Each asks the provider, then saves its answer the way webhooks do: the
  hooks above run for the change. Not every provider can change plans or
  resume; `supports?/2` says.

  ## Revenue

  Give plans their prices (`amount`, `annual_amount`, `currency`, in minor
  units such as cents) and `monthly_amount/2` turns a subscription into its
  monthly recurring amount, to add up by currency:

      [name: "pro", id: "price_pro", annual_id: "price_pro_year",
       amount: 2_000, annual_amount: 20_000, currency: "usd"]

      Authmk.Payments.monthly_amount(MyApp.Auth, subscription)
      #=> {2_000, "usd"}
  """

  alias Authmk.{Context, Error}
  alias Authmk.Payments.{Actions, Plans, Reference}
  alias Authmk.Payments.Store, as: Billing

  @typedoc "Who's billed: a user's id, or `{:organization, id}`."
  @type billed :: term() | {:organization, term()}

  @doc "A user's or organization's subscriptions, newest first."
  @spec subscriptions(module(), billed()) :: [struct()]
  def subscriptions(auth, reference),
    do: Billing.list(Context.new(auth.config()), Reference.from_app(reference))

  @doc "The subscription that counts now (active or trialing), or `nil`."
  @spec active_subscription(module(), billed()) :: struct() | nil
  def active_subscription(auth, reference),
    do: auth |> subscriptions(reference) |> Enum.find(&Billing.active?/1)

  @doc "Whether a subscription counts now: active or trialing, and not past its period."
  @spec active?(struct()) :: boolean()
  def active?(subscription), do: Billing.active?(subscription)

  @doc "The plan (from the plugin's `plans`) of the active subscription, or `nil`."
  @spec plan(module(), billed()) :: keyword() | nil
  def plan(auth, reference) do
    with %{plan: name} when is_binary(name) <- active_subscription(auth, reference),
         {_plugin, opts} <- provider(auth) do
      Enum.find(opts[:plans], &(to_string(&1[:name]) == name))
    else
      _none -> nil
    end
  end

  @doc """
  Whether the active plan allows `wanted` of `limit` (from its `limits`):
  `false` without an active plan or that limit.
  """
  @spec allowed?(module(), billed(), atom(), number()) :: boolean()
  def allowed?(auth, reference, limit, wanted \\ 1) do
    case plan(auth, reference) do
      nil ->
        false

      plan ->
        case (plan[:limits] || %{})[limit] do
          true -> true
          max when is_number(max) -> wanted <= max
          _none -> false
        end
    end
  end

  @doc """
  The payment plugin (an `Authmk.Payments.Provider`) and its options, or
  `nil` when there's none.
  """
  @spec provider(module()) :: {module(), keyword()} | nil
  def provider(auth) do
    config = auth.config()

    Enum.find(config.plugins, fn {plugin, _opts} ->
      Code.ensure_loaded?(plugin) and function_exported?(plugin, :provider, 0) and
        Map.has_key?(config.schema.models, :subscription)
    end)
  end

  @doc """
  Whether the payment plugin can do `action` through its provider:
  `:cancel` (all of them), `:change_plan` or `:resume`. `false` without one.
  """
  @spec supports?(module(), :cancel | :change_plan | :resume) :: boolean()
  def supports?(auth, action) do
    case provider(auth) do
      {plugin, _opts} -> Actions.supported?(plugin, action)
      nil -> false
    end
  end

  @doc """
  Cancels a subscription (by its id in the database) at the provider: at
  the end of its period, or now with `immediately: true`. Returns it as
  saved.

  Errors: `subscription_not_found`, `subscription_canceled` (already),
  `not_supported` (billed by another provider), `feature_disabled` (no
  payment plugin), and the provider's `payment_provider_error` or
  `payment_provider_unavailable`.
  """
  @spec cancel(module(), term(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def cancel(auth, subscription_id, opts \\ []) do
    immediately = Keyword.get(opts, :immediately, false)
    with_provider(auth, &Actions.cancel(&1, &2, subscription_id, immediately))
  end

  @doc """
  Undoes a cancel scheduled for the end of the period, at the provider.
  Returns the subscription as saved.

  Errors, besides `cancel/3`'s: `not_scheduled_to_cancel`, and
  `not_supported` when the provider can't (see `supports?/2`).
  """
  @spec resume(module(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def resume(auth, subscription_id),
    do: with_provider(auth, &Actions.resume(&1, &2, subscription_id))

  @doc """
  Moves a subscription to the plan named `plan_name` (from `plans`), at
  the provider and with its proration rules: its `id`, or its `annual_id`
  with `annual: true`. A user or organization that had a trial gets the
  plan's `no_trial_id` when it has one, as at checkout. Returns the
  subscription as saved, with the new plan's name.

  Some providers schedule a change (a downgrade, say) for the end of the
  period: the subscription then keeps its plan until a webhook reports the
  change.

  Errors, besides `cancel/3`'s: `plan_not_found` (no such plan, or no
  `annual_id` for `annual: true`), `not_supported` when the provider can't
  (see `supports?/2`), and with Commet `plan_change_needs_payment`, when
  the customer must pay for the change themselves (in the billing portal).
  """
  @spec change_plan(module(), term(), String.t() | atom(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def change_plan(auth, subscription_id, plan_name, opts \\ []) do
    annual = Keyword.get(opts, :annual, false)
    with_provider(auth, &Actions.change_plan(&1, &2, subscription_id, plan_name, annual))
  end

  @doc """
  A subscription's monthly recurring amount, from its plan's prices:
  `{amount, currency}`, with `amount` in minor units (cents) and the
  plan's lowercase `currency`. That's the plan's `amount` for its `id` or
  `no_trial_id` (`id` is taken to bill monthly), or its `annual_amount` / 12,
  rounded, for its `annual_id`; times the subscription's `seats`, when it
  has them.

  `nil` when the subscription's price id matches no plan, or that plan has
  no price for it. It doesn't look at the status: pick the subscriptions
  that count (with `active?/1`, say) before adding them up.
  """
  @spec monthly_amount(module(), struct()) :: {non_neg_integer(), String.t()} | nil
  def monthly_amount(auth, subscription) do
    case provider(auth) do
      {_plugin, opts} -> Plans.monthly_amount(opts[:plans], subscription)
      nil -> nil
    end
  end

  defp with_provider(auth, action) do
    case provider(auth) do
      {_plugin, _opts} = provider -> action.(Context.new(auth.config()), provider)
      nil -> {:error, Error.new(:feature_disabled)}
    end
  end
end
