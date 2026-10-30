defmodule Authmk.Payments.Actions do
  @moduledoc false
  # Cancel, resume and change plan from server code (an admin dashboard,
  # the app's own back office), behind Authmk.Payments. The provider is
  # asked first; its answer is saved the way webhooks save it, so the same
  # lifecycle hooks fire and the plan's name comes from the price id.

  alias Authmk.Error
  alias Authmk.Payments.{Options, Plans, Store}

  # What each action calls on the plugin: name and arity.
  @callbacks %{cancel: 4, change_plan: 4, resume: 3}

  @doc "Whether `plugin` implements `action`."
  def supported?(plugin, action) when is_map_key(@callbacks, action),
    do: Code.ensure_loaded?(plugin) and function_exported?(plugin, action, @callbacks[action])

  def supported?(_plugin, _action), do: false

  def cancel(ctx, {plugin, opts}, id, immediately) do
    with {:ok, subscription} <- find(ctx, plugin, id),
         :ok <- not_canceled(subscription),
         {:ok, attrs} <- plugin.cancel(ctx, subscription, not immediately, opts) do
      save(ctx, {plugin, opts}, subscription, attrs)
    end
  end

  def resume(ctx, {plugin, opts}, id) do
    with :ok <- supported(plugin, :resume),
         {:ok, subscription} <- find(ctx, plugin, id),
         :ok <- not_canceled(subscription),
         :ok <- scheduled_to_cancel(subscription),
         {:ok, attrs} <- plugin.resume(ctx, subscription, opts) do
      save(ctx, {plugin, opts}, subscription, attrs)
    end
  end

  def change_plan(ctx, {plugin, opts}, id, plan_name, annual) do
    with :ok <- supported(plugin, :change_plan),
         {:ok, plan} <- Plans.by_name(opts[:plans], plan_name),
         :ok <- has_annual_price(plan, annual),
         {:ok, subscription} <- find(ctx, plugin, id),
         :ok <- not_canceled(subscription) do
      price_id = Plans.price_id(plan, annual, trial_allowed?(ctx, subscription))
      switch(ctx, {plugin, opts}, subscription, price_id)
    end
  end

  # Already on that price: nothing to ask the provider.
  defp switch(_ctx, _plugin, %{price_id: price_id} = subscription, price_id),
    do: {:ok, subscription}

  defp switch(ctx, {plugin, opts}, subscription, price_id) do
    with {:ok, attrs} <- plugin.change_plan(ctx, subscription, price_id, opts),
         do: save(ctx, {plugin, opts}, subscription, attrs)
  end

  # One trial per reference, as at checkout: a plan whose product has a
  # trial is billed with its `no_trial_id` once the reference had one.
  defp trial_allowed?(ctx, subscription) do
    reference = %{type: subscription.reference_type, id: subscription.reference_id}
    not Store.had_trial?(ctx, reference)
  end

  defp find(ctx, plugin, id) do
    provider = plugin.provider()

    case Store.get_by_id(ctx, id) do
      nil ->
        {:error, Error.custom(:subscription_not_found, 404, "No such subscription")}

      %{provider: ^provider} = subscription ->
        {:ok, subscription}

      _another_providers ->
        {:error,
         Error.custom(:not_supported, 400, "This subscription is billed by another provider")}
    end
  end

  # The provider's answer is about the subscription asked for: it keeps
  # that id, and its customer when the answer leaves it out.
  defp save(ctx, {plugin, opts}, subscription, attrs) do
    attrs =
      attrs
      |> Map.put(:provider_subscription_id, subscription.provider_subscription_id)
      |> Map.update(:customer_id, subscription.customer_id, &(&1 || subscription.customer_id))
      |> Map.put(:plan, Plans.name_for(opts[:plans], attrs[:price_id]))

    Store.sync(ctx, plugin.provider(), attrs, Keyword.take(opts, Options.hooks()))
  end

  defp supported(plugin, action) do
    if supported?(plugin, action),
      do: :ok,
      else:
        {:error, Error.custom(:not_supported, 400, "The payment provider doesn't support this")}
  end

  defp has_annual_price(plan, annual) do
    if annual and is_nil(plan[:annual_id]),
      do: {:error, Error.custom(:plan_not_found, 404, "This plan has no annual price")},
      else: :ok
  end

  defp not_canceled(%{status: "canceled"}),
    do: {:error, Error.custom(:subscription_canceled, 409, "The subscription is canceled")}

  defp not_canceled(_subscription), do: :ok

  defp scheduled_to_cancel(%{cancel_at_period_end: true}), do: :ok

  defp scheduled_to_cancel(_subscription),
    do:
      {:error,
       Error.custom(:not_scheduled_to_cancel, 409, "The subscription isn't set to cancel")}
end
