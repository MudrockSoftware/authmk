defmodule Authmk.Payments.Endpoints do
  @moduledoc false
  # The endpoints every payment plugin shares; the plugin (an
  # Authmk.Payments.Provider) talks to its provider.

  require Logger

  alias Authmk.{Context, Endpoint, Error, Origin, Serializer}
  alias Authmk.Payments.{Options, Reference, Store}
  alias Authmk.Plug.RawBody

  @doc "The shared endpoints, for `endpoints/1` of a payment plugin."
  def endpoints do
    reference = [reference_id: [type: :string]]

    [
      Endpoint.new(
        name: :billing_checkout,
        method: :post,
        path: "/billing/checkout",
        handler: {__MODULE__, :checkout},
        session: :required,
        params:
          reference ++
            [
              plan: [type: :string, required: true],
              annual: [type: :boolean, default: false],
              seats: [type: :integer],
              success_url: [type: :string, required: true],
              cancel_url: [type: :string]
            ]
      ),
      Endpoint.new(
        name: :billing_subscriptions,
        method: :get,
        path: "/billing/subscriptions",
        handler: {__MODULE__, :subscriptions},
        session: :required,
        params: reference
      ),
      Endpoint.new(
        name: :billing_portal,
        method: :post,
        path: "/billing/portal",
        handler: {__MODULE__, :portal},
        session: :required,
        params: reference ++ [return_url: [type: :string, required: true]]
      ),
      Endpoint.new(
        name: :billing_cancel,
        method: :post,
        path: "/billing/cancel",
        handler: {__MODULE__, :cancel},
        session: :required,
        params:
          reference ++
            [
              subscription_id: [type: :string, required: true],
              immediately: [type: :boolean, default: false]
            ]
      ),
      # The provider calls it, from its servers: no session, no Origin.
      Endpoint.new(
        name: :billing_webhook,
        method: :post,
        path: "/billing/webhook",
        handler: {__MODULE__, :webhook},
        origin_check: false,
        rate_limit: [window: 10, max: 1000]
      )
    ]
  end

  @doc false
  def checkout(%Context{params: params} = ctx) do
    {plugin, opts} = plugin(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :checkout, opts),
         trial_allowed = not Store.had_trial?(ctx, reference.id),
         {:ok, success_url} <- absolute(ctx, params.success_url),
         {:ok, cancel_url} <- absolute(ctx, params.cancel_url || params.success_url),
         {:ok, plan} <- plan(opts, params.plan),
         :ok <- not_subscribed(ctx, reference, plan),
         {:ok, customer_id} <- ensure_customer(ctx, plugin, reference, opts) do
      checkout = %{
        customer_id: customer_id,
        price_id: price_id(plan, params.annual, trial_allowed),
        success_url: success_url,
        cancel_url: cancel_url,
        seats: params.seats,
        # One trial per reference, whatever the plan or provider.
        trial_days: if(trial_allowed, do: plan[:trial_days]),
        trial_allowed: trial_allowed,
        reference: reference
      }

      with {:ok, url} <- plugin.checkout(ctx, checkout, opts),
           do: {:ok, %{url: url, redirect: true}, ctx}
    end
  end

  @doc false
  def subscriptions(%Context{params: params} = ctx) do
    {_plugin, opts} = plugin(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :list, opts) do
      {:ok, ctx |> Store.list(reference.id) |> Enum.map(&serialize(ctx, &1)), ctx}
    end
  end

  @doc false
  def portal(%Context{params: params} = ctx) do
    {plugin, opts} = plugin(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :portal, opts),
         {:ok, return_url} <- absolute(ctx, params.return_url),
         %{customer_id: customer_id} <-
           Store.customer(ctx, plugin.provider(), reference.id) || {:error, no_customer()},
         {:ok, url} <-
           plugin.portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
      {:ok, %{url: url, redirect: true}, ctx}
    end
  end

  @doc false
  def cancel(%Context{params: params} = ctx) do
    {plugin, opts} = plugin(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :cancel, opts),
         %{} = subscription <-
           Store.get_for_reference(ctx, reference.id, params.subscription_id) ||
             {:error, not_found()},
         {:ok, attrs} <- plugin.cancel(ctx, subscription, not params.immediately, opts),
         {:ok, subscription} <- Store.sync(ctx, plugin.provider(), attrs, hooks(opts)) do
      {:ok, serialize(ctx, subscription), ctx}
    end
  end

  @doc false
  def webhook(%Context{conn: conn} = ctx) do
    {plugin, opts} = plugin(ctx)
    headers = Map.new(conn.req_headers)

    with body when is_binary(body) <- RawBody.get(conn) || {:error, :raw_body_unavailable},
         {:ok, subscriptions} <- plugin.webhook(ctx, body, headers, opts) do
      Enum.each(subscriptions, &sync(ctx, plugin, opts, &1))
      {:json, 200, %{received: true}, ctx}
    else
      {:error, :raw_body_unavailable} ->
        Logger.error(
          "authmk billing webhook: no raw body. Add Authmk.Plug.RawBody to Plug.Parsers"
        )

        {:json, 500, %{error: "raw_body_unavailable"}, ctx}

      {:error, reason} ->
        Logger.warning("authmk billing webhook refused (#{reason})")
        {:json, 400, %{error: "invalid_webhook"}, ctx}
    end
  end

  defp sync(ctx, plugin, opts, attrs) do
    provider = plugin.provider()
    reference = reference_of(ctx, provider, attrs)

    if reference || Store.get(ctx, provider, attrs.provider_subscription_id) do
      attrs =
        attrs
        |> Map.drop([:reference_id, :reference_type])
        |> Map.merge(reference || %{})
        |> Map.put(:plan, plan_name(opts, attrs[:price_id]))

      save(ctx, provider, attrs, opts)
    else
      Logger.warning("authmk billing: a subscription for an unknown customer was ignored")
    end
  end

  defp save(ctx, provider, attrs, opts) do
    case Store.sync(ctx, provider, attrs, hooks(opts)) do
      {:ok, _subscription} -> :ok
      {:error, error} -> Logger.warning("authmk billing: subscription not saved (#{error.code})")
    end
  end

  # Whose subscription it is: the reference checkout put in its metadata,
  # or the customer we know.
  defp reference_of(_ctx, _provider, %{reference_id: id} = attrs) when is_binary(id) and id != "",
    do: %{reference_id: id, reference_type: attrs[:reference_type] || "user"}

  defp reference_of(ctx, provider, attrs) do
    case Store.customer_by_id(ctx, provider, attrs.customer_id) do
      nil -> nil
      customer -> %{reference_id: customer.reference_id, reference_type: customer.reference_type}
    end
  end

  @doc false
  # Background work (create_customer_on_sign_up): the new user's customer.
  def create_customer_for(ctx, plugin, user) do
    reference = %{id: to_string(user.id), type: "user", email: user.email, name: user.name}
    {_plugin, opts} = {plugin, Context.plugin_opts(ctx, plugin)}

    case ensure_customer(ctx, plugin, reference, opts) do
      {:ok, _customer_id} -> :ok
      {:error, error} -> Logger.warning("authmk billing: customer not created (#{error.code})")
    end
  end

  defp ensure_customer(ctx, plugin, reference, opts) do
    case Store.customer(ctx, plugin.provider(), reference.id) do
      %{customer_id: customer_id} ->
        {:ok, customer_id}

      nil ->
        with {:ok, customer_id} <- plugin.create_customer(ctx, reference, opts),
             {:ok, _customer} <-
               Store.put_customer(ctx, plugin.provider(), reference, customer_id),
             do: {:ok, customer_id}
    end
  end

  # Providers with trials on the product take another product without one,
  # once the reference had its trial.
  defp price_id(plan, annual, trial_allowed) do
    cond do
      not trial_allowed and plan[:no_trial_id] -> plan[:no_trial_id]
      annual and plan[:annual_id] -> plan[:annual_id]
      true -> plan[:id]
    end
  end

  # The same plan again: change plans in the provider's portal instead.
  defp not_subscribed(ctx, reference, plan) do
    if Enum.any?(Store.list(ctx, reference.id), &(Store.active?(&1) and &1.plan == plan[:name])),
      do: {:error, Error.custom(:already_subscribed, 409, "Already subscribed to this plan")},
      else: :ok
  end

  defp plan(opts, name) do
    case Enum.find(opts[:plans], &(to_string(&1[:name]) == name)) do
      nil -> {:error, Error.custom(:plan_not_found, 404, "No such plan")}
      plan -> {:ok, plan}
    end
  end

  defp plan_name(opts, price_id) when is_binary(price_id) do
    Enum.find_value(opts[:plans], fn plan ->
      price_id in [plan[:id], plan[:annual_id], plan[:no_trial_id]] and to_string(plan[:name])
    end)
  end

  defp plan_name(_opts, _price_id), do: nil

  # Providers need absolute URLs; ours must be safe redirects first.
  defp absolute(ctx, url) do
    with :ok <- Origin.check_redirect(ctx, url) do
      if String.starts_with?(url, "/"),
        do: {:ok, String.trim_trailing(ctx.base_url, "/") <> url},
        else: {:ok, url}
    end
  end

  defp hooks(opts), do: Keyword.take(opts, Options.hooks())

  defp plugin(%Context{endpoint: %{plugin: plugin}} = ctx),
    do: {plugin, Context.plugin_opts(ctx, plugin)}

  defp serialize(ctx, subscription) do
    ctx
    |> Serializer.record(:subscription, subscription)
    |> Map.put(:active, Store.active?(subscription))
  end

  defp no_customer, do: Error.custom(:no_billing_customer, 404, "There's no billing account yet")
  defp not_found, do: Error.custom(:subscription_not_found, 404, "No such subscription")
end
