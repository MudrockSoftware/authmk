defmodule Authmk.Plugins.DodoPayments do
  @moduledoc """
  Subscriptions with Dodo Payments: checkout, the customer portal and
  webhooks.

      use Authmk,
        plugins: [
          {Authmk.Plugins.DodoPayments,
           api_key: &MyApp.dodo_key/0,
           webhook_secret: &MyApp.dodo_webhook_secret/0,
           environment: :live,
           plans: [[name: "pro", id: "pdt_123", trial_days: 7]]}
        ],
        ...

  The endpoints, plans, trials, organizations and hooks are
  `Authmk.Payments`'. A plan's `trial_days` overrides the product's trial;
  without it, the product's own trial stands. A user or organization that
  had a trial checks out with none: authmk sends `trial_period_days: 0`,
  which overrides the product's trial.

  In Dodo, add a webhook endpoint for `<base URL>/billing/webhook` with the
  `subscription.*` events. Webhooks are checked as Dodo signs them
  (Standard Webhooks, at most 5 minutes old), then the subscription is
  read from Dodo again.

  `Authmk.Payments.change_plan/4` moves the subscription to the plan's
  product, prorated and charged now (`prorated_immediately`), and
  `Authmk.Payments.resume/2` takes back a cancel set for the next billing
  date.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.DodoPayments.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error}
  alias Authmk.Payments.{Client, Endpoints, Options, Schema, Webhook}
  alias Authmk.Plugins.DodoPayments.Options, as: DodoOptions

  @servers %{live: "https://live.dodopayments.com", test: "https://test.dodopayments.com"}

  @impl Authmk.Plugin
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema(DodoOptions.own()))

  @impl Authmk.Plugin
  def schema(_opts), do: Schema.models()

  @impl Authmk.Plugin
  def endpoints(_opts), do: Endpoints.endpoints()

  @impl Authmk.Plugin
  def database_hook(:after_create, :user, user, %Context{} = ctx) do
    if Context.plugin_opts(ctx, __MODULE__)[:create_customer_on_sign_up],
      do: Background.call(ctx, Endpoints, :create_customer_for, [__MODULE__, user])

    :ok
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @impl Authmk.Payments.Provider
  def provider, do: "dodo_payments"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    body = %{
      email: reference.email,
      name: reference.name || reference.email,
      metadata: %{reference_id: reference.id, reference_type: reference.type}
    }

    with {:ok, %{"customer_id" => id}} <- request(ctx, :post, "/customers", body, opts),
         do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    body =
      %{
        product_cart: [%{product_id: checkout.price_id, quantity: checkout.seats || 1}],
        customer: %{customer_id: checkout.customer_id},
        return_url: checkout.success_url,
        metadata: %{reference_id: checkout.reference.id, reference_type: checkout.reference.type}
      }
      |> trial(checkout)

    with {:ok, %{"checkout_url" => url}} <- request(ctx, :post, "/checkouts", body, opts),
         do: {:ok, url}
  end

  # `trial_period_days` overrides the product's trial: 0 once the trial has
  # been had, the plan's days otherwise. Omitting it leaves the product's.
  defp trial(body, %{trial_allowed: false}),
    do: Map.put(body, :subscription_data, %{trial_period_days: 0})

  defp trial(body, %{trial_days: days}) when is_integer(days),
    do: Map.put(body, :subscription_data, %{trial_period_days: days})

  defp trial(body, _checkout), do: body

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    path =
      "/customers/#{URI.encode(customer_id)}/customer-portal/session?" <>
        URI.encode_query(return_url: return_url)

    with {:ok, %{"link" => url}} <- request(ctx, :post, path, nil, opts), do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    path = subscription_path(subscription)

    body =
      if at_period_end,
        do: %{cancel_at_next_billing_date: true},
        else: %{status: "cancelled"}

    with {:ok, _updated} <- request(ctx, :patch, path, body, opts),
         {:ok, object} <- request(ctx, :get, path, nil, opts),
         do: {:ok, normalize(object)}
  end

  # Prorated, and charged now; the seats stay as they are.
  @impl Authmk.Payments.Provider
  def change_plan(ctx, subscription, product_id, opts) do
    path = subscription_path(subscription)

    body = %{
      product_id: product_id,
      quantity: subscription.seats || 1,
      proration_billing_mode: "prorated_immediately"
    }

    with {:ok, _changed} <- request(ctx, :post, path <> "/change-plan", body, opts),
         {:ok, object} <- request(ctx, :get, path, nil, opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def resume(ctx, subscription, opts) do
    path = subscription_path(subscription)

    with {:ok, _updated} <-
           request(ctx, :patch, path, %{cancel_at_next_billing_date: false}, opts),
         {:ok, object} <- request(ctx, :get, path, nil, opts),
         do: {:ok, normalize(object)}
  end

  defp subscription_path(subscription),
    do: "/subscriptions/" <> URI.encode(subscription.provider_subscription_id)

  @impl Authmk.Payments.Provider
  def webhook(ctx, body, headers, opts) do
    headers = %{
      id: headers["webhook-id"],
      timestamp: headers["webhook-timestamp"],
      signature: headers["webhook-signature"]
    }

    key = Webhook.standard_key(Options.secret(opts[:webhook_secret]))

    with :ok <- Webhook.standard(headers, body, key),
         {:ok, %{"type" => "subscription." <> _, "data" => %{"subscription_id" => id}}} <-
           JSON.decode(body),
         {:ok, object} <- request(ctx, :get, "/subscriptions/" <> URI.encode(id), nil, opts) do
      {:ok, [normalize(object)]}
    else
      {:ok, _other_event} -> {:ok, []}
      {:error, %Error{}} -> {:error, :subscription_unavailable}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _undecodable} -> {:error, :invalid_payload}
    end
  end

  @doc false
  # Dodo has no trialing status, and `trial_period_days` stays on the
  # subscription after the trial (0 when there was none). The window runs
  # from `created_at`. Recording `trial_start` is what stops a second trial:
  # a later checkout would otherwise send the length again, and Dodo grants it.
  def normalize(object) do
    %{
      provider_subscription_id: object["subscription_id"],
      customer_id: get_in(object, ["customer", "customer_id"]),
      status: status(object),
      price_id: object["product_id"],
      seats: object["quantity"],
      period_start: Client.time(object["previous_billing_date"]),
      period_end: Client.time(object["next_billing_date"]),
      cancel_at_period_end: object["cancel_at_next_billing_date"] == true,
      canceled_at: Client.time(object["cancelled_at"]),
      trial_start: trial_start(object),
      trial_end: trial_end(object)
    }
  end

  # Dodo's statuses, in Authmk.Payments' words. An active subscription still
  # inside its trial window is trialing.
  defp status(object) do
    mapped =
      case object["status"] do
        "pending" -> "incomplete"
        "on_hold" -> "past_due"
        "cancelled" -> "canceled"
        "expired" -> "canceled"
        "failed" -> "canceled"
        status -> status
      end

    if mapped == "active" and in_trial?(object), do: "trialing", else: mapped
  end

  defp in_trial?(object) do
    case trial_end(object) do
      %DateTime{} = ends -> DateTime.after?(ends, DateTime.utc_now())
      _none -> false
    end
  end

  defp trial_start(object) do
    case trial_window(object) do
      {start, _ends} -> start
      nil -> nil
    end
  end

  defp trial_end(object) do
    case trial_window(object) do
      {_start, ends} -> ends
      nil -> nil
    end
  end

  defp trial_window(%{"trial_period_days" => days} = object) when is_integer(days) and days > 0 do
    case Client.time(object["created_at"]) do
      %DateTime{} = start -> {start, DateTime.add(start, days * 86_400, :second)}
      nil -> nil
    end
  end

  defp trial_window(_object), do: nil

  defp request(ctx, method, path, body, opts) do
    headers = [{"authorization", "Bearer " <> Options.secret(opts[:api_key])}]

    Client.request(
      ctx,
      method,
      @servers[opts[:environment]] <> path,
      body,
      headers,
      "Dodo Payments"
    )
  end
end
