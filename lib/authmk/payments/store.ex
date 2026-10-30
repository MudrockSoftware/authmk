defmodule Authmk.Payments.Store do
  @moduledoc false
  # Customers and subscriptions in the database, kept in step with the
  # provider by its webhooks. Every change to a subscription fires the
  # app's lifecycle hooks: `on_subscription_created`, `_updated`,
  # `_canceled`, `on_trial_started`, `on_trial_ended`.

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.{Context, Store}

  @active ~w(active trialing)

  def customer(ctx, provider, reference_id) do
    ctx
    |> Store.all(:billing_customer, provider: provider, reference_id: to_string(reference_id))
    |> List.first()
  end

  def customer_by_id(ctx, provider, customer_id),
    do: Store.get_by(ctx, :billing_customer, provider: provider, customer_id: customer_id)

  def put_customer(ctx, provider, reference, customer_id) do
    Store.insert(ctx, :billing_customer, %{
      provider: provider,
      reference_id: to_string(reference.id),
      reference_type: reference.type,
      customer_id: customer_id
    })
  end

  @doc "A reference's subscriptions, newest first."
  def list(ctx, reference_id) do
    condition = dynamic([s], s.reference_id == ^to_string(reference_id))

    ctx
    |> Store.all(:subscription, condition, limit: 100)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  def get(ctx, provider, provider_subscription_id),
    do:
      Store.get_by(ctx, :subscription,
        provider: provider,
        provider_subscription_id: provider_subscription_id
      )

  def get_for_reference(ctx, reference_id, id) do
    case Store.get_by(ctx, :subscription, id: id) do
      %{reference_id: ^reference_id} = subscription -> subscription
      _other -> nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Whether it counts: active or trialing, and not past its period."
  def active?(%{status: status} = subscription) when status in @active do
    is_nil(subscription.period_end) or
      DateTime.after?(subscription.period_end, DateTime.utc_now())
  end

  def active?(_subscription), do: false

  @doc "Whether the reference ever had a trial, with any provider: one per reference."
  def had_trial?(ctx, reference_id) do
    condition =
      dynamic(
        [s],
        s.reference_id == ^to_string(reference_id) and
          (not is_nil(s.trial_start) or s.status == "trialing")
      )

    Store.all(ctx, :subscription, condition, limit: 1) != []
  end

  @doc """
  Creates or updates a subscription from the provider's word (`attrs`
  with `provider_subscription_id`), and tells the app what changed.
  """
  def sync(%Context{} = ctx, provider, attrs, hooks) do
    previous = get(ctx, provider, attrs.provider_subscription_id)
    attrs = Map.put(attrs, :provider, provider)

    # A trial's start stays known, even when later updates leave it out.
    attrs =
      if previous && is_nil(attrs[:trial_start]), do: Map.delete(attrs, :trial_start), else: attrs

    result =
      if previous,
        do:
          Store.update(
            ctx,
            :subscription,
            previous,
            Map.drop(attrs, [:reference_id, :reference_type])
          ),
        else: Store.insert(ctx, :subscription, attrs)

    with {:ok, subscription} <- result do
      notify(ctx, hooks, previous, subscription)
      {:ok, subscription}
    end
  end

  defp notify(ctx, hooks, previous, subscription) do
    for {hook, true} <- changes(previous, subscription), fun = hooks[hook], fun do
      fun.(subscription, ctx)
    end

    :ok
  end

  defp changes(nil, now) do
    [
      on_subscription_created: true,
      on_subscription_canceled: canceled?(now),
      on_trial_started: not is_nil(now.trial_start)
    ]
  end

  defp changes(previous, now) do
    [
      on_subscription_updated: true,
      on_subscription_canceled: canceled?(now) and not canceled?(previous),
      on_trial_started: is_nil(previous.trial_start) and not is_nil(now.trial_start),
      on_trial_ended: previous.status == "trialing" and now.status != "trialing"
    ]
  end

  # Canceled now, or set to end with its period.
  defp canceled?(subscription),
    do: subscription.status == "canceled" or subscription.cancel_at_period_end
end
