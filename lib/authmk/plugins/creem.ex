defmodule Authmk.Plugins.Creem do
  @moduledoc """
  Subscriptions with Creem: checkout, the customer portal, access checks,
  webhooks and trial-abuse prevention.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Creem,
           api_key: &MyApp.creem_key/0,
           webhook_secret: &MyApp.creem_webhook_secret/0,
           plans: [
             [name: "pro", id: "prod_with_trial", no_trial_id: "prod_without_trial",
              limits: %{projects: 20}]
           ]}
        ],
        ...

  The endpoints, plans, organizations and hooks are `Authmk.Payments`', and
  so are access checks (`Authmk.Payments.allowed?/4`, by the plan's
  `limits`).

  Trials are set on Creem's products, and Creem keeps no record of who had
  one. authmk does: a user or organization that had a trial, with any plan,
  checks out with the plan's `no_trial_id` product instead, so a trial
  can't be had twice by cancelling and subscribing again.

  In Creem, add a webhook for `<base URL>/billing/webhook`. Creem signs only
  the body (no timestamp), so a captured webhook could be sent again: authmk
  uses it only to know which subscription changed, and reads that
  subscription from Creem.

  `Authmk.Payments.change_plan/4` upgrades the subscription to the plan's
  product (prorated and charged now, Creem's default), and
  `Authmk.Payments.resume/2` takes back a scheduled cancel.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Creem.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error}
  alias Authmk.Payments.{Client, Endpoints, Options, Reference, Schema, Webhook}
  alias Authmk.Plugins.Creem.Options, as: CreemOptions

  @servers %{production: "https://api.creem.io/v1", test: "https://test-api.creem.io/v1"}

  @impl Authmk.Plugin
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema(CreemOptions.own()))

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
  def provider, do: "creem"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    body = %{
      email: reference.email,
      name: reference.name || reference.email,
      external_id: Reference.external_id(reference),
      metadata: %{reference_type: reference.type}
    }

    with {:ok, %{"id" => id}} <- request(ctx, :post, "/customers", body, opts), do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    body = %{
      product_id: checkout.price_id,
      units: checkout.seats || 1,
      success_url: checkout.success_url,
      customer: %{id: checkout.customer_id},
      metadata: %{reference_id: checkout.reference.id, reference_type: checkout.reference.type}
    }

    with {:ok, %{"checkout_url" => url}} <- request(ctx, :post, "/checkouts", body, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id}, opts) do
    with {:ok, %{"customer_portal_link" => url}} <-
           request(ctx, :post, "/customers/billing", %{customer_id: customer_id}, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    id = subscription.provider_subscription_id
    mode = if at_period_end, do: "scheduled", else: "immediate"

    with {:ok, _canceled} <-
           request(ctx, :post, "/subscriptions/#{URI.encode(id)}/cancel", %{mode: mode}, opts),
         {:ok, object} <- fetch(ctx, id, opts),
         do: {:ok, normalize(object)}
  end

  # Creem's default: prorated, and charged now.
  @impl Authmk.Payments.Provider
  def change_plan(ctx, subscription, product_id, opts) do
    id = subscription.provider_subscription_id
    path = "/subscriptions/#{URI.encode(id)}/upgrade"

    with {:ok, _upgraded} <- request(ctx, :post, path, %{product_id: product_id}, opts),
         {:ok, object} <- fetch(ctx, id, opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def resume(ctx, subscription, opts) do
    id = subscription.provider_subscription_id

    with {:ok, _resumed} <-
           request(ctx, :post, "/subscriptions/#{URI.encode(id)}/resume", %{}, opts),
         {:ok, object} <- fetch(ctx, id, opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def webhook(ctx, body, headers, opts) do
    with :ok <-
           Webhook.hex(headers["creem-signature"], body, Options.secret(opts[:webhook_secret])),
         {:ok, event} <- JSON.decode(body) do
      refetch(ctx, subscription_id(event), opts)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _undecodable} -> {:error, :invalid_payload}
    end
  end

  defp subscription_id(%{"eventType" => "subscription." <> _, "object" => %{"id" => id}}), do: id

  defp subscription_id(%{
         "eventType" => "checkout.completed",
         "object" => %{"subscription" => subscription}
       }),
       do: id(subscription)

  defp subscription_id(_event), do: nil

  defp refetch(_ctx, nil, _opts), do: {:ok, []}

  defp refetch(ctx, id, opts) do
    case fetch(ctx, id, opts) do
      {:ok, object} -> {:ok, [normalize(object)]}
      {:error, %Error{}} -> {:error, :subscription_unavailable}
    end
  end

  defp fetch(ctx, id, opts),
    do: request(ctx, :get, "/subscriptions?" <> URI.encode_query(subscription_id: id), nil, opts)

  @doc false
  def normalize(object) do
    %{
      provider_subscription_id: object["id"],
      customer_id: id(object["customer"]),
      status: status(object["status"]),
      price_id: id(object["product"]),
      seats: seats(object["items"]),
      period_start: Client.time(object["current_period_start_date"]),
      period_end: Client.time(object["current_period_end_date"]),
      cancel_at_period_end: object["status"] == "scheduled_cancel",
      canceled_at: Client.time(object["canceled_at"]),
      trial_start: trial_start(object)
    }
  end

  defp seats([%{"units" => units} | _items]) when is_integer(units), do: units
  defp seats(_items), do: nil

  # Creem keeps no trial dates on the subscription: one of a product with a
  # trial began with one, when it was created (or trialing now, when seen).
  defp trial_start(object) do
    trial_days = get_in(object, ["product", "trial_period_days"])

    cond do
      is_integer(trial_days) and trial_days > 0 ->
        Client.time(object["created_at"]) || DateTime.utc_now()

      object["status"] == "trialing" ->
        DateTime.utc_now()

      true ->
        nil
    end
  end

  # Creem's statuses, in Authmk.Payments' words.
  defp status("scheduled_cancel"), do: "active"
  defp status(status), do: status

  defp id(%{"id" => id}), do: id
  defp id(id) when is_binary(id), do: id
  defp id(_none), do: nil

  defp request(ctx, method, path, body, opts) do
    headers = [{"x-api-key", Options.secret(opts[:api_key])}]
    Client.request(ctx, method, @servers[opts[:environment]] <> path, body, headers, "Creem")
  end
end
