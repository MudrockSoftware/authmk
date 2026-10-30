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
  `Authmk.Payments`'. A plan's `trial_days` overrides the product's; a user
  or organization that had a trial checks out with none.

  In Dodo, add a webhook endpoint for `<base URL>/billing/webhook` with the
  `subscription.*` events. Webhooks are checked as Dodo signs them
  (Standard Webhooks, at most 5 minutes old), then the subscription is
  read from Dodo again.

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
    body = %{
      product_cart: [%{product_id: checkout.price_id, quantity: checkout.seats || 1}],
      customer: %{customer_id: checkout.customer_id},
      return_url: checkout.success_url,
      metadata: %{reference_id: checkout.reference.id, reference_type: checkout.reference.type},
      subscription_data: %{trial_period_days: checkout.trial_days || 0}
    }

    with {:ok, %{"checkout_url" => url}} <- request(ctx, :post, "/checkouts", body, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    path =
      "/customers/#{URI.encode(customer_id)}/customer-portal/session?" <>
        URI.encode_query(return_url: return_url)

    with {:ok, %{"link" => url}} <- request(ctx, :post, path, nil, opts), do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    path = "/subscriptions/" <> URI.encode(subscription.provider_subscription_id)

    body =
      if at_period_end,
        do: %{cancel_at_next_billing_date: true},
        else: %{status: "cancelled"}

    with {:ok, _updated} <- request(ctx, :patch, path, body, opts),
         {:ok, object} <- request(ctx, :get, path, nil, opts),
         do: {:ok, normalize(object)}
  end

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
  def normalize(object) do
    %{
      provider_subscription_id: object["subscription_id"],
      customer_id: get_in(object, ["customer", "customer_id"]),
      status: status(object["status"]),
      price_id: object["product_id"],
      seats: object["quantity"],
      period_start: Client.time(object["previous_billing_date"]),
      period_end: Client.time(object["next_billing_date"]),
      cancel_at_period_end: object["cancel_at_next_billing_date"] == true,
      canceled_at: Client.time(object["cancelled_at"])
    }
  end

  # Dodo's statuses, in Authmk.Payments' words.
  defp status("pending"), do: "incomplete"
  defp status("on_hold"), do: "past_due"
  defp status("cancelled"), do: "canceled"
  defp status("expired"), do: "canceled"
  defp status("failed"), do: "canceled"
  defp status(status), do: status

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
