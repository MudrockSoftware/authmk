defmodule Authmk.Plugins.Polar do
  @moduledoc """
  Subscriptions and usage-based billing with Polar: checkout, the customer
  portal, usage events, meters and webhooks.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Polar,
           api_key: &MyApp.polar_token/0,
           webhook_secret: &MyApp.polar_webhook_secret/0,
           server: :production,
           plans: [[name: "pro", id: "<product uuid>"]]}
        ],
        ...

  The endpoints, plans, trials, organizations and hooks are
  `Authmk.Payments`'. Polar's customers get `user_<id>` (or `org_<id>`) as
  their `external_id`.
  Trials are set on Polar's products; a user or organization that had one
  checks out with `allow_trial: false`.

  In Polar, add a webhook endpoint for `<base URL>/billing/webhook` with the
  `subscription.*` events. Webhooks are checked as Polar signs them
  (Standard Webhooks, at most 5 minutes old; secrets made before and after
  Polar's September 2026 change both work), then the subscription is read
  from Polar again.

  `Authmk.Payments.change_plan/4` moves the subscription to the plan's
  product (prorated by your organization's default; Polar may apply it at
  the period's end), and `Authmk.Payments.resume/2` takes back a cancel
  set for the period's end.

  Usage, from your code:

      Authmk.Plugins.Polar.track(MyApp.Auth, user.id, "ai_tokens", %{tokens: 1200})
      Authmk.Plugins.Polar.meters(MyApp.Auth, {:organization, org.id})

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Polar.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error}
  alias Authmk.Payments.{Client, Endpoints, Options, Reference, Schema, Webhook}
  alias Authmk.Plugins.Polar.Options, as: PolarOptions

  @servers %{production: "https://api.polar.sh/v1", sandbox: "https://sandbox-api.polar.sh/v1"}

  @impl Authmk.Plugin
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema(PolarOptions.own()))

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
  def provider, do: "polar"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    body = %{
      email: reference.email,
      name: reference.name,
      external_id: Reference.external_id(reference),
      metadata: %{reference_type: reference.type}
    }

    case request(ctx, :post, "/customers/", body, opts) do
      {:ok, %{"id" => id}} -> {:ok, id}
      # Made before (the external id is taken): that one.
      {:error, _error} -> existing_customer(ctx, body.external_id, opts)
    end
  end

  defp existing_customer(ctx, external_id, opts) do
    with {:ok, %{"id" => id}} <-
           request(ctx, :get, "/customers/external/" <> URI.encode(external_id), nil, opts),
         do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    body = %{
      products: [checkout.price_id],
      customer_id: checkout.customer_id,
      success_url: checkout.success_url,
      return_url: checkout.cancel_url,
      allow_trial: checkout.trial_allowed,
      metadata: %{reference_id: checkout.reference.id, reference_type: checkout.reference.type}
    }

    with {:ok, %{"url" => url}} <- request(ctx, :post, "/checkouts/", body, opts), do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    body = %{customer_id: customer_id, return_url: return_url}

    with {:ok, %{"customer_portal_url" => url}} <-
           request(ctx, :post, "/customer-sessions/", body, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    path = subscription_path(subscription)

    result =
      if at_period_end,
        do: request(ctx, :patch, path, %{cancel_at_period_end: true}, opts),
        else: request(ctx, :delete, path, nil, opts)

    with {:ok, object} <- result, do: {:ok, normalize(object)}
  end

  # Polar prorates by the organization's default, and may keep the change
  # pending until the period ends (its webhook says when it's done).
  @impl Authmk.Payments.Provider
  def change_plan(ctx, subscription, product_id, opts) do
    with {:ok, object} <-
           request(ctx, :patch, subscription_path(subscription), %{product_id: product_id}, opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def resume(ctx, subscription, opts) do
    body = %{cancel_at_period_end: false}

    with {:ok, object} <- request(ctx, :patch, subscription_path(subscription), body, opts),
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

    with :ok <- verify(headers, body, Options.secret(opts[:webhook_secret])),
         {:ok, %{"type" => "subscription." <> _, "data" => %{"id" => id}}} when is_binary(id) <-
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

  # Polar's secrets made before September 2026 key the HMAC with the whole
  # `whsec_...` string; newer ones with the base64 after the prefix. Which
  # one a secret is can't be told from it: either may sign.
  defp verify(headers, body, secret) do
    keys = [secret | List.wrap(decoded(secret))]

    if Enum.any?(keys, &(Webhook.standard(headers, body, &1) == :ok)),
      do: :ok,
      else: Webhook.standard(headers, body, secret)
  end

  defp decoded("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> key
      :error -> nil
    end
  end

  defp decoded(_secret), do: nil

  @doc false
  def normalize(object) do
    %{
      provider_subscription_id: object["id"],
      customer_id: object["customer_id"],
      status: status(object["status"]),
      price_id: object["product_id"],
      seats: object["seats"],
      period_start: Client.time(object["current_period_start"]),
      period_end: Client.time(object["current_period_end"]),
      cancel_at_period_end: object["cancel_at_period_end"] == true,
      canceled_at: Client.time(object["canceled_at"]),
      trial_start: Client.time(object["trial_start"]),
      trial_end: Client.time(object["trial_end"])
    }
  end

  defp status("incomplete_expired"), do: "canceled"
  defp status(status), do: status

  @doc """
  Records a usage event for a user (by id) or `{:organization, id}`, for
  Polar's meters: `name` and `metadata` (up to 50 keys).
  """
  @spec track(module(), Authmk.Payments.billed(), String.t(), map()) ::
          :ok | {:error, Error.t()}
  def track(auth, reference, name, metadata \\ %{}) do
    {ctx, opts} = server(auth)
    event = %{name: name, external_customer_id: external_id(reference), metadata: metadata}

    with {:ok, _counts} <- request(ctx, :post, "/events/ingest", %{events: [event]}, opts),
         do: :ok
  end

  @doc "A user's or organization's meters: Polar's customer meters (`consumed_units`, `balance`...)."
  @spec meters(module(), Authmk.Payments.billed()) :: {:ok, [map()]} | {:error, Error.t()}
  def meters(auth, reference) do
    {ctx, opts} = server(auth)
    query = URI.encode_query(external_customer_id: external_id(reference))

    with {:ok, %{"items" => items}} <-
           request(ctx, :get, "/customer-meters/?" <> query, nil, opts),
         do: {:ok, items}
  end

  defp external_id(reference), do: reference |> Reference.from_app() |> Reference.external_id()

  defp server(auth) do
    ctx = Context.new(auth.config())
    {ctx, Context.plugin_opts(ctx, __MODULE__)}
  end

  defp request(ctx, method, path, body, opts) do
    headers = [{"authorization", "Bearer " <> Options.secret(opts[:api_key])}]
    Client.request(ctx, method, @servers[opts[:server]] <> path, body, headers, "Polar")
  end
end
