defmodule Authmk.Payments.Plans do
  @moduledoc false
  # The payment plugin's `plans`: found by name, or by the provider's price
  # id, and what they cost a month.

  alias Authmk.Error

  @doc "The plan named `name` (a string or an atom)."
  def by_name(plans, name) do
    case Enum.find(plans, &(to_string(&1[:name]) == to_string(name))) do
      nil -> {:error, Error.custom(:plan_not_found, 404, "No such plan")}
      plan -> {:ok, plan}
    end
  end

  @doc "The plan one of whose ids is `price_id`, or `nil`."
  def by_price(plans, price_id) when is_binary(price_id),
    do: Enum.find(plans, &(price_id in [&1[:id], &1[:annual_id], &1[:no_trial_id]]))

  def by_price(_plans, _price_id), do: nil

  @doc "The name of the plan with `price_id`, as subscriptions store it, or `nil`."
  def name_for(plans, price_id) do
    case by_price(plans, price_id) do
      nil -> nil
      plan -> to_string(plan[:name])
    end
  end

  @doc """
  Which of the plan's ids to bill. Providers with trials on the product
  take another product without one, once the reference had its trial.
  """
  def price_id(plan, annual, trial_allowed) do
    cond do
      not trial_allowed and plan[:no_trial_id] -> plan[:no_trial_id]
      annual and plan[:annual_id] -> plan[:annual_id]
      true -> plan[:id]
    end
  end

  @doc """
  `{amount, currency}` a month for a subscription, by its price id: the
  plan's `amount`, or its `annual_amount` / 12 for `annual_id`, times its
  seats. `nil` without a matching plan or a price for that id.
  """
  def monthly_amount(plans, subscription) do
    seats = subscription.seats || 1

    case by_price(plans, subscription.price_id) do
      nil -> nil
      plan -> monthly(plan, subscription.price_id == plan[:annual_id], seats)
    end
  end

  defp monthly(plan, true = _annual, seats) do
    case plan[:annual_amount] do
      nil -> nil
      yearly -> {round(yearly * seats / 12), plan[:currency]}
    end
  end

  defp monthly(plan, false = _annual, seats) do
    case plan[:amount] do
      nil -> nil
      monthly -> {monthly * seats, plan[:currency]}
    end
  end
end
