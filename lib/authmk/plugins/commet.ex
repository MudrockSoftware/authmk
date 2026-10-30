defmodule Authmk.Plugins.Commet do
  @moduledoc """
  Subscriptions, feature access, usage and seats with Commet.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Commet,
           api_key: &MyApp.commet_key/0,
           webhook_secret: &MyApp.commet_webhook_secret/0,
           plans: [[name: "pro", id: "<plan id>", trial_days: 14]]}
        ],
        ...

  The endpoints (checkout, subscriptions, the customer portal, cancel),
  plans, organizations and hooks are `Authmk.Payments`'. Sandbox and live
  are told apart by the key (`ck_sandbox_`, `ck_live_`). A user or
  organization that had a trial checks out with `skipTrial`.

  Commet decides what a customer may use. From your code:

      Authmk.Plugins.Commet.check(MyApp.Auth, user.id, "api_calls")      # {:ok, true}
      Authmk.Plugins.Commet.track(MyApp.Auth, user.id, "api_calls", 1)
      Authmk.Plugins.Commet.set_seats(MyApp.Auth, org.id, "editor_seats", 12)

  `check/3` answers `false` when Commet can't be asked: no access on an
  outage.

  In Commet, add a webhook for `<base URL>/billing/webhook`. Commet signs
  only the body (no timestamp), so a captured webhook could be sent again:
  authmk uses it only to know which subscription changed, and reads that
  subscription from Commet.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Commet.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error}
  alias Authmk.Payments.{Client, Endpoints, Options, Schema, Store, Webhook}
  alias Authmk.Plugins.Commet.Options, as: CommetOptions

  @api "https://commet.co/api/v1"

  @impl Authmk.Plugin
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema(CommetOptions.own()))

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
  def provider, do: "commet"

  @impl Authmk.Payments.Provider
  def create_customer(ctx, reference, opts) do
    body = %{email: reference.email, externalId: reference.id, fullName: reference.name}
    with {:ok, %{"id" => id}} <- request(ctx, :post, "/customers", body, opts), do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    body =
      %{
        customerId: checkout.customer_id,
        planId: checkout.price_id,
        successUrl: checkout.success_url,
        initialSeats: checkout.seats,
        customTrialDays: checkout.trial_days,
        skipTrial: not checkout.trial_allowed
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case request(ctx, :post, "/subscriptions", body, opts) do
      {:ok, %{"checkoutUrl" => url}} when is_binary(url) -> {:ok, url}
      # Nothing to pay (a free plan, a trial without a card): it's on already.
      {:ok, %{}} -> {:ok, checkout.success_url}
      {:error, error} -> {:error, error}
    end
  end

  @impl Authmk.Payments.Provider
  def portal(ctx, %{customer_id: customer_id, return_url: return_url}, opts) do
    body = %{customerId: customer_id, returnUrl: return_url}

    with {:ok, %{"portalUrl" => url}} <- request(ctx, :post, "/portal/sessions", body, opts),
         do: {:ok, url}
  end

  @impl Authmk.Payments.Provider
  def cancel(ctx, subscription, at_period_end, opts) do
    path = "/subscriptions/#{URI.encode(subscription.provider_subscription_id)}/cancel"

    with {:ok, object} <- request(ctx, :post, path, %{immediate: not at_period_end}, opts),
         do: {:ok, normalize(object)}
  end

  @impl Authmk.Payments.Provider
  def webhook(ctx, body, headers, opts) do
    secret = Options.secret(opts[:webhook_secret])

    with :ok <- Webhook.hex(headers["x-commet-signature"], body, secret),
         {:ok, event} <- JSON.decode(body) do
      case event do
        %{"event" => "subscription." <> _, "data" => %{"subscriptionId" => id}} ->
          refetch(ctx, id, opts)

        %{"event" => "trial." <> _, "data" => %{"subscriptionId" => id}} ->
          refetch(ctx, id, opts)

        _other ->
          {:ok, []}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _undecodable} -> {:error, :invalid_payload}
    end
  end

  defp refetch(ctx, id, opts) do
    case request(ctx, :get, "/subscriptions/" <> URI.encode(id), nil, opts) do
      {:ok, object} -> {:ok, [normalize(object)]}
      {:error, _error} -> {:error, :subscription_unavailable}
    end
  end

  @doc false
  def normalize(object) do
    period = object["currentPeriod"] || %{}

    %{
      provider_subscription_id: object["id"],
      customer_id: object["customerId"],
      status: status(object["status"]),
      price_id: get_in(object, ["plan", "id"]),
      period_start: Client.time(period["start"]),
      period_end: Client.time(period["end"]),
      cancel_at_period_end: object["cancelAtPeriodEnd"] == true,
      canceled_at: Client.time(get_in(object, ["cancellation", "scheduledAt"])),
      trial_end: Client.time(object["trialEndsAt"]),
      # Commet says when a trial ends, not when it began: trialing now is when it's seen.
      trial_start: if(object["status"] == "trialing", do: DateTime.utc_now())
    }
  end

  # Commet's statuses, in Authmk.Payments' words.
  defp status("draft"), do: "incomplete"
  defp status("pending_payment"), do: "incomplete"
  defp status(status), do: status

  @doc """
  Whether a user or organization may use `feature` (Commet's feature
  code), by its plan and usage. `false` when Commet can't be asked, or the
  reference has no customer yet.
  """
  @spec check(module(), term(), String.t()) :: {:ok, boolean()}
  def check(auth, reference_id, feature) do
    {ctx, opts} = server(auth)

    with %{customer_id: customer_id} <- Store.customer(ctx, provider(), reference_id),
         query = URI.encode_query(customerId: customer_id),
         {:ok, %{"allowed" => true}} <-
           request(ctx, :get, "/feature-access/#{URI.encode(feature)}?" <> query, nil, opts) do
      {:ok, true}
    else
      _no -> {:ok, false}
    end
  end

  @doc "Records `value` units of usage of `feature` for a user or organization."
  @spec track(module(), term(), String.t(), number()) :: :ok | {:error, Error.t()}
  def track(auth, reference_id, feature, value \\ 1) do
    with {:ok, ctx, opts, customer_id} <- customer(auth, reference_id),
         {:ok, _event} <-
           request(
             ctx,
             :post,
             "/usage/events",
             %{featureCode: feature, customerId: customer_id, value: value},
             opts
           ),
         do: :ok
  end

  @doc "Sets a user's or organization's seats of `feature`."
  @spec set_seats(module(), term(), String.t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def set_seats(auth, reference_id, feature, count) do
    with {:ok, ctx, opts, customer_id} <- customer(auth, reference_id),
         {:ok, _event} <-
           request(
             ctx,
             :put,
             "/seats",
             %{customerId: customer_id, featureCode: feature, count: count},
             opts
           ),
         do: :ok
  end

  defp customer(auth, reference_id) do
    {ctx, opts} = server(auth)

    case Store.customer(ctx, provider(), reference_id) do
      %{customer_id: customer_id} -> {:ok, ctx, opts, customer_id}
      nil -> {:error, Error.custom(:no_billing_customer, 404, "There's no billing account yet")}
    end
  end

  defp server(auth) do
    ctx = Context.new(auth.config())
    {ctx, Context.plugin_opts(ctx, __MODULE__)}
  end

  defp request(ctx, method, path, body, opts) do
    headers = [
      {"x-api-key", Options.secret(opts[:api_key])},
      {"commet-version", opts[:api_version]}
    ]

    Client.request(ctx, method, @api <> path, body, headers, "Commet")
  end
end
