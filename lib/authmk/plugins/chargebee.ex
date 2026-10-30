defmodule Authmk.Plugins.Chargebee do
  @moduledoc """
  Subscriptions with Chargebee: customers, hosted checkout pages, the
  self-serve portal, webhooks and trials.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Chargebee,
           site: "acme",
           api_key: &MyApp.chargebee_key/0,
           webhook_secret: &MyApp.chargebee_webhook_credentials/0,
           plans: [[name: "pro", id: "pro-USD-Monthly", trial_days: 14]]}
        ],
        ...

  `id` is an item price id. The endpoints, plans, trials, organizations and
  hooks are `Authmk.Payments`'. A plan's `trial_days` sets the trial; a user
  or organization that had one checks out with none.

  Chargebee doesn't sign webhooks: protect the webhook with Basic auth
  (Settings > Webhooks), and give authmk the same `"username:password"` as
  `webhook_secret`. Since nothing signs the content, authmk uses a webhook
  only to know which subscription changed, and reads it from Chargebee.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Chargebee.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error}
  alias Authmk.OAuth.HTTP
  alias Authmk.Payments.{Client, Endpoints, Options, Schema}
  alias Authmk.Plugins.Chargebee.Options, as: ChargebeeOptions

  @impl Authmk.Plugin
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema(ChargebeeOptions.own()))

    # It goes into the API's host name: a site name, nothing else.
    if not Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, opts[:site]),
      do: raise(ArgumentError, "Chargebee's site must be a site name, like \"acme\"")

    opts
  end

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
  def provider, do: "chargebee"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    {first_name, last_name} = names(reference.name)

    form = [
      {"email", reference.email},
      {"first_name", first_name},
      {"last_name", last_name},
      {"company", if(reference.type == "organization", do: reference.name)}
    ]

    with {:ok, %{"customer" => %{"id" => id}}} <- request(ctx, :post, "/customers", form, opts),
         do: {:ok, id}
  end

  defp names(nil), do: {nil, nil}

  defp names(name) do
    case String.split(name, " ", parts: 2) do
      [first, last] -> {first, last}
      [first] -> {first, nil}
    end
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    form = [
      {"customer[id]", checkout.customer_id},
      {"subscription_items[item_price_id][0]", checkout.price_id},
      {"subscription_items[quantity][0]", to_string(checkout.seats || 1)},
      {"redirect_url", checkout.success_url},
      {"cancel_url", checkout.cancel_url},
      # 0: no trial (the item price's own, too), once the reference had one.
      {"subscription[trial_end]", to_string(trial_end(checkout.trial_days))}
    ]

    with {:ok, %{"hosted_page" => %{"url" => url}}} <-
           request(ctx, :post, "/hosted_pages/checkout_new_for_items", form, opts),
         do: {:ok, url}
  end

  defp trial_end(nil), do: 0
  defp trial_end(days), do: System.system_time(:second) + days * 86_400

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    form = [{"customer[id]", customer_id}, {"redirect_url", return_url}]

    with {:ok, %{"portal_session" => %{"access_url" => url}}} <-
           request(ctx, :post, "/portal_sessions", form, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    option = if at_period_end, do: "end_of_term", else: "immediately"
    path = "/subscriptions/#{URI.encode(subscription.provider_subscription_id)}/cancel_for_items"

    with {:ok, %{"subscription" => object}} <-
           request(ctx, :post, path, [{"cancel_option", option}], opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def webhook(ctx, body, headers, opts) do
    with :ok <- basic_auth(headers["authorization"], Options.secret(opts[:webhook_secret])),
         {:ok, event} <- JSON.decode(body) do
      refetch(ctx, subscription_id(event), opts)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _undecodable} -> {:error, :invalid_payload}
    end
  end

  defp subscription_id(%{
         "event_type" => "subscription_" <> _,
         "content" => %{"subscription" => %{"id" => id}}
       }),
       do: id

  defp subscription_id(_event), do: nil

  defp refetch(_ctx, nil, _opts), do: {:ok, []}

  defp refetch(ctx, id, opts) do
    case request(ctx, :get, "/subscriptions/" <> URI.encode(id), nil, opts) do
      {:ok, %{"subscription" => object}} -> {:ok, [normalize(object)]}
      _unavailable -> {:error, :subscription_unavailable}
    end
  end

  defp basic_auth("Basic " <> encoded, credentials) when is_binary(credentials) do
    if Plug.Crypto.secure_compare(encoded, Base.encode64(credentials)),
      do: :ok,
      else: {:error, :invalid_credentials}
  end

  defp basic_auth(_header, _credentials), do: {:error, :invalid_credentials}

  @doc false
  def normalize(object) do
    item =
      Enum.find(object["subscription_items"] || [], &(&1["item_type"] == "plan")) ||
        List.first(object["subscription_items"] || []) || %{}

    %{
      provider_subscription_id: object["id"],
      customer_id: object["customer_id"],
      status: status(object["status"]),
      price_id: item["item_price_id"],
      seats: item["quantity"],
      period_start: Client.time(object["current_term_start"]),
      period_end: Client.time(object["current_term_end"]),
      cancel_at_period_end: object["status"] == "non_renewing",
      canceled_at: Client.time(object["cancelled_at"]),
      trial_start: Client.time(object["trial_start"]),
      trial_end: Client.time(object["trial_end"])
    }
  end

  # Chargebee's statuses, in Authmk.Payments' words.
  defp status("future"), do: "incomplete"
  defp status("in_trial"), do: "trialing"
  defp status("non_renewing"), do: "active"
  defp status("cancelled"), do: "canceled"
  defp status("transferred"), do: "canceled"
  defp status(status), do: status

  defp request(ctx, method, path, form, opts) do
    url = "https://#{opts[:site]}.chargebee.com/api/v2" <> path

    headers = [
      {"authorization", "Basic " <> Base.encode64(Options.secret(opts[:api_key]) <> ":")}
    ]

    result =
      case method do
        :get -> HTTP.get(ctx, url, headers)
        :post -> HTTP.post_form(ctx, url, Enum.reject(form, &is_nil(elem(&1, 1))), headers)
      end

    case result do
      {:ok, status, %{} = body} when status in 200..299 ->
        {:ok, body}

      {:ok, _status, _body} ->
        {:error, Error.custom(:payment_provider_error, 502, "Chargebee refused the request")}

      {:error, _reason} ->
        {:error, Error.custom(:payment_provider_unavailable, 502, "Chargebee can't be reached")}
    end
  end
end
