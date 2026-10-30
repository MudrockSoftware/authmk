defmodule Authmk.Payments do
  @moduledoc """
  Subscriptions, whichever payment plugin bills them:
  `Authmk.Plugins.Stripe`, `Authmk.Plugins.Polar`, `Authmk.Plugins.Chargebee`,
  `Authmk.Plugins.Creem` or `Authmk.Plugins.DodoPayments` (one per app).

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
  waiting for a payment) can't check out again: plans are changed and
  payments fixed in the provider's portal, so nobody pays twice.

  From your code, check what a user or organization has with the functions
  below. They take a user's id, or `{:organization, id}`:

      Authmk.Payments.allowed?(MyApp.Auth, user.id, :projects, 3)
      Authmk.Payments.plan(MyApp.Auth, {:organization, org.id})
  """

  alias Authmk.Context
  alias Authmk.Payments.Reference
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

  @doc "The plan (from the plugin's `plans`) of the active subscription, or `nil`."
  @spec plan(module(), billed()) :: keyword() | nil
  def plan(auth, reference) do
    with %{plan: name} when is_binary(name) <- active_subscription(auth, reference),
         {_plugin, opts} <- plugin(auth) do
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

  defp plugin(auth) do
    config = auth.config()

    Enum.find(config.plugins, fn {plugin, _opts} ->
      Code.ensure_loaded?(plugin) and function_exported?(plugin, :provider, 0) and
        Map.has_key?(config.schema.models, :subscription)
    end)
  end
end
