defmodule Authmk.Plugins.Stripe do
  @moduledoc """
  Subscriptions with Stripe: customers, Checkout, the customer portal,
  webhooks, trials, lifecycle hooks, organization subscriptions and tax.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Stripe,
           api_key: &MyApp.stripe_key/0,
           webhook_secret: &MyApp.stripe_webhook_secret/0,
           plans: [
             [name: "pro", id: "price_123", annual_id: "price_456", trial_days: 14,
              limits: %{projects: 20}]
           ],
           automatic_tax: true,
           on_subscription_created: &MyApp.Billing.welcome/2}
        ],
        ...

  The endpoints, plans, trials, organizations and hooks are
  `Authmk.Payments`'. In Stripe, add a webhook endpoint for
  `<base URL>/billing/webhook` with the `customer.subscription.*` and
  `checkout.session.completed` events, and put its signing secret in
  `webhook_secret`.

  `Authmk.Payments.change_plan/4` gives the subscription's item the plan's
  price (keeping its quantity, prorated by your account's default), and
  `Authmk.Payments.resume/2` sets `cancel_at_period_end` back to false.

  Webhooks are checked against the `Stripe-Signature` header (HMAC-SHA256
  over the timestamp and the exact body, at most 5 minutes old). Then the
  subscription is read from Stripe again: webhooks can come out of order
  or twice, and Stripe's own word now is what's stored.

  Requests pin Stripe's API version (`api_version`), so payloads don't
  change under you; pin your webhook endpoint to the same version.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Stripe.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error, Log}
  alias Authmk.OAuth.HTTP
  alias Authmk.Payments.{Endpoints, Options, Schema, Webhook}
  alias Authmk.Plugins.Stripe.Options, as: StripeOptions

  @api "https://api.stripe.com/v1"
  @subscription_events ~w(customer.subscription.created customer.subscription.updated
                          customer.subscription.deleted customer.subscription.paused
                          customer.subscription.resumed customer.subscription.trial_will_end)

  @impl Authmk.Plugin
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema(StripeOptions.own()))

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
  def provider, do: "stripe"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    form = [
      {"email", reference.email},
      {"name", reference.name},
      {"metadata[reference_id]", reference.id},
      {"metadata[reference_type]", reference.type}
    ]

    with {:ok, %{"id" => id}} <- request(ctx, :post, "/customers", form, opts), do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    reference = checkout.reference

    form =
      [
        {"mode", "subscription"},
        {"customer", checkout.customer_id},
        {"line_items[0][price]", checkout.price_id},
        {"line_items[0][quantity]", to_string(checkout.seats || 1)},
        {"success_url", checkout.success_url},
        {"cancel_url", checkout.cancel_url},
        {"client_reference_id", reference.id},
        # On the subscription itself: its webhooks say whose it is.
        {"subscription_data[metadata][reference_id]", reference.id},
        {"subscription_data[metadata][reference_type]", reference.type}
      ] ++
        if(checkout.trial_days,
          do: [{"subscription_data[trial_period_days]", to_string(checkout.trial_days)}],
          else: []
        ) ++
        tax(opts) ++
        if(opts[:allow_promotion_codes], do: [{"allow_promotion_codes", "true"}], else: [])

    with {:ok, %{"url" => url}} <- request(ctx, :post, "/checkout/sessions", form, opts),
         do: {:ok, url}
  end

  # Stripe Tax needs the customer's address: Checkout asks and saves it.
  defp tax(opts) do
    if(opts[:automatic_tax],
      do: [
        {"automatic_tax[enabled]", "true"},
        {"customer_update[address]", "auto"},
        {"customer_update[name]", "auto"}
      ],
      else: []
    ) ++
      if(opts[:tax_id_collection], do: [{"tax_id_collection[enabled]", "true"}], else: [])
  end

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    form = [{"customer", customer_id}, {"return_url", return_url}]

    with {:ok, %{"url" => url}} <- request(ctx, :post, "/billing_portal/sessions", form, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    path = subscription_path(subscription)

    result =
      if at_period_end,
        do: request(ctx, :post, path, [{"cancel_at_period_end", "true"}], opts),
        else: request(ctx, :delete, path, [], opts)

    with {:ok, object} <- result, do: {:ok, normalize(object)}
  end

  # The subscription's item gets the new price, and keeps its quantity.
  # Stripe prorates by the account's default.
  @impl Authmk.Payments.Provider
  def change_plan(ctx, subscription, price_id, opts) do
    path = subscription_path(subscription)

    with {:ok, object} <- request(ctx, :get, path, [], opts),
         {:ok, item_id} <- item_id(object),
         form = [{"items[0][id]", item_id}, {"items[0][price]", price_id}],
         {:ok, updated} <- request(ctx, :post, path, form, opts),
         do: {:ok, normalize(updated)}
  end

  defp item_id(object) do
    case get_in(object, ["items", "data"]) do
      [%{"id" => id} | _items] when is_binary(id) ->
        {:ok, id}

      _none ->
        Log.warning("authmk Stripe subscription has no item to change")
        {:error, Error.custom(:payment_provider_error, 502, "Stripe refused the request")}
    end
  end

  @impl Authmk.Payments.Provider
  def resume(ctx, subscription, opts) do
    form = [{"cancel_at_period_end", "false"}]

    with {:ok, object} <- request(ctx, :post, subscription_path(subscription), form, opts),
         do: {:ok, normalize(object)}
  end

  defp subscription_path(subscription),
    do: "/subscriptions/" <> URI.encode_www_form(subscription.provider_subscription_id)

  @impl Authmk.Payments.Provider
  def webhook(ctx, body, headers, opts) do
    secret = Options.secret(opts[:webhook_secret])

    with :ok <- Webhook.stripe(headers["stripe-signature"], body, secret),
         {:ok, event} <- JSON.decode(body) do
      refetch(ctx, subscription_id(event), opts)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _undecodable} -> {:error, :invalid_payload}
    end
  end

  defp subscription_id(%{"type" => type, "data" => %{"object" => %{"id" => id}}})
       when type in @subscription_events,
       do: id

  defp subscription_id(%{
         "type" => "checkout.session.completed",
         "data" => %{"object" => %{"mode" => "subscription", "subscription" => id}}
       })
       when is_binary(id),
       do: id

  defp subscription_id(_event), do: nil

  # Stripe's word now, not the event's: events come out of order, or twice.
  defp refetch(_ctx, nil, _opts), do: {:ok, []}

  defp refetch(ctx, id, opts) do
    case request(ctx, :get, "/subscriptions/" <> URI.encode_www_form(id), [], opts) do
      {:ok, object} -> {:ok, [normalize(object)]}
      {:error, _error} -> {:error, :subscription_unavailable}
    end
  end

  @doc false
  # Stripe's subscription, as Authmk.Payments stores it. Periods are on the
  # items in current API versions, on the subscription in older ones.
  def normalize(object) do
    item = get_in(object, ["items", "data"]) |> List.wrap() |> List.first() || %{}
    metadata = object["metadata"] || %{}

    %{
      provider_subscription_id: object["id"],
      customer_id: object["customer"],
      status: status(object["status"]),
      price_id: get_in(item, ["price", "id"]),
      seats: item["quantity"],
      period_start: time(item["current_period_start"] || object["current_period_start"]),
      period_end: time(item["current_period_end"] || object["current_period_end"]),
      cancel_at_period_end:
        object["cancel_at_period_end"] == true or not is_nil(object["cancel_at"]),
      canceled_at: time(object["canceled_at"]),
      trial_start: time(object["trial_start"]),
      trial_end: time(object["trial_end"]),
      reference_id: metadata["reference_id"],
      reference_type: metadata["reference_type"]
    }
  end

  defp status("incomplete_expired"), do: "canceled"
  defp status(status), do: status

  defp time(nil), do: nil
  defp time(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  defp request(ctx, method, path, form, opts) do
    headers = [
      {"authorization", "Bearer " <> Options.secret(opts[:api_key])},
      {"stripe-version", opts[:api_version]}
    ]

    result =
      case method do
        :get ->
          HTTP.get(ctx, @api <> path, headers)

        :delete ->
          HTTP.delete(ctx, @api <> path, headers)

        :post ->
          HTTP.post_form(ctx, @api <> path, Enum.reject(form, &is_nil(elem(&1, 1))), headers)
      end

    case result do
      {:ok, status, %{} = body} when status in 200..299 -> {:ok, body}
      {:ok, _status, body} -> {:error, stripe_error(body)}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # What Stripe said goes to the logs, not to the user.
  defp stripe_error(body) do
    case body do
      %{"error" => %{"code" => code}} when is_binary(code) ->
        Log.warning("authmk Stripe refused a request (#{code})")

      _other ->
        Log.warning("authmk Stripe refused a request")
    end

    Error.custom(:payment_provider_error, 502, "Stripe refused the request")
  end

  defp unavailable,
    do: Error.custom(:payment_provider_unavailable, 502, "Stripe can't be reached")
end
