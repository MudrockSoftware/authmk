defmodule Authmk.Dashboard.Data.Payments do
  @moduledoc false
  # Subscriptions and earnings (with a payment plugin, see Authmk.Payments).
  # Recurring revenue is worked out from the subscriptions webhooks stored
  # and the plans' prices in config (`amount`, `annual_amount`, `currency`):
  # authmk doesn't keep invoices, so it's what active subscriptions bill a
  # month, not money received.

  import Ecto.Query

  alias Authmk.Dashboard.Data
  alias Authmk.Dashboard.Data.Analytics
  alias Authmk.{Payments, Store}

  # Subscriptions summed for recurring revenue, at most.
  @max_active 50_000

  @doc "The provider, its plans with prices, and what it can do."
  def setup(ctx) do
    case Payments.provider(ctx.config.auth) do
      nil ->
        nil

      {plugin, opts} ->
        auth = ctx.config.auth

        %{
          provider: plugin.provider(),
          plans:
            for plan <- opts[:plans] do
              %{
                name: to_string(plan[:name]),
                amount: plan[:amount],
                annual_amount: plan[:annual_amount],
                currency: plan[:currency],
                annual: not is_nil(plan[:annual_id])
              }
            end,
          supports: %{
            cancel: Payments.supports?(auth, :cancel),
            change_plan: Payments.supports?(auth, :change_plan),
            resume: Payments.supports?(auth, :resume)
          }
        }
    end
  end

  @doc "Recurring revenue now, and new and cancelled subscriptions per day in the range."
  def earnings(ctx, first, last) do
    active = active(ctx)

    priced =
      for subscription <- active,
          do: {subscription, Payments.monthly_amount(ctx.config.auth, subscription)}

    %{
      from: first,
      to: last,
      active_subscriptions: length(active),
      unpriced_subscriptions:
        Enum.count(priced, fn {_subscription, amount} -> is_nil(amount) end),
      recurring_revenue: totals(priced, fn _subscription -> %{} end),
      by_plan:
        totals(priced, fn subscription ->
          %{plan: subscription.plan, provider: subscription.provider}
        end),
      by_status: by_status(ctx),
      new_subscriptions: Analytics.per_day_of(ctx, :subscription, :inserted_at, first, last),
      cancellations: Analytics.per_day_of(ctx, :subscription, :canceled_at, first, last)
    }
  end

  defp active(ctx) do
    ctx
    |> Store.list(
      :subscription,
      from(s in Store.module(ctx, :subscription),
        where: s.status in ["active", "trialing"],
        limit: @max_active
      )
    )
    |> Enum.filter(&Payments.active?/1)
  end

  # Monthly amounts added up per currency (amounts in different currencies
  # don't add), and per whatever `key` gives.
  defp totals(priced, key) do
    priced
    |> Enum.group_by(fn {subscription, amount} ->
      Map.put(key.(subscription), :currency, amount && elem(amount, 1))
    end)
    |> Enum.map(fn {group, rows} ->
      monthly =
        rows |> Enum.map(fn {_s, amount} -> (amount && elem(amount, 0)) || 0 end) |> Enum.sum()

      Map.merge(group, %{monthly: monthly, yearly: monthly * 12, subscriptions: length(rows)})
    end)
    |> Enum.sort_by(&{-&1.monthly, &1[:plan] || ""})
  end

  defp by_status(ctx) do
    from(s in Store.module(ctx, :subscription),
      group_by: s.status,
      select: {s.status, count(s.id)}
    )
    |> then(&Store.list(ctx, :subscription, &1))
    |> Map.new()
  end

  @doc """
  Subscriptions, newest first, with whose they are. `filters`: `:status`,
  `:plan`, `:reference_type` (`user` or `organization`).
  """
  def list(ctx, filters, offset) do
    query =
      from(s in Store.module(ctx, :subscription),
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: ^(Data.page_size() + 1),
        offset: ^offset
      )

    query =
      Enum.reduce(filters, query, fn
        {_field, nil}, query -> query
        {field, value}, query -> where(query, [s], field(s, ^field) == ^value)
      end)

    subscriptions = Store.list(ctx, :subscription, query)
    names = reference_names(ctx, subscriptions)

    for subscription <- subscriptions do
      subscription
      |> Data.subscription()
      |> Map.put(:reference_name, names[{subscription.reference_type, subscription.reference_id}])
      |> Map.put(:monthly_amount, monthly(ctx, subscription))
    end
  end

  defp monthly(ctx, subscription) do
    case Payments.monthly_amount(ctx.config.auth, subscription) do
      {amount, currency} -> %{amount: amount, currency: currency}
      nil -> nil
    end
  end

  def find(ctx, id), do: Data.safe_get(ctx, :subscription, id)

  # Who each subscription bills: a user's email or an organization's name.
  defp reference_names(ctx, subscriptions) do
    by_type = Enum.group_by(subscriptions, & &1.reference_type, & &1.reference_id)

    Map.merge(
      names(ctx, :user, by_type["user"], & &1.email),
      names(ctx, :organization, by_type["organization"], & &1.name)
    )
  end

  defp names(_ctx, _model, nil, _name), do: %{}

  defp names(ctx, model, ids, name) do
    type = Atom.to_string(model)

    if Data.model?(ctx, model) do
      ids
      |> Enum.uniq()
      |> Enum.flat_map(fn id -> List.wrap(Data.safe_get(ctx, model, id)) end)
      |> Map.new(&{{type, to_string(&1.id)}, name.(&1)})
    else
      %{}
    end
  end
end
