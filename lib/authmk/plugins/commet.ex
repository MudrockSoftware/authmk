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
      Authmk.Plugins.Commet.set_seats(MyApp.Auth, {:organization, org.id}, "editor_seats", 12)

  `check/3` answers `false` when Commet can't be asked: no access on an
  outage.

  In Commet, add a webhook for `<base URL>/billing/webhook`. Commet signs
  only the body (no timestamp), so a captured webhook could be sent again:
  authmk uses it only to know which subscription changed, and reads that
  subscription from Commet.

  `Authmk.Payments.change_plan/4` asks Commet to change the plan: it
  applies upgrades now and schedules downgrades for renewal. A change the
  customer must pay for at a checkout is refused with
  `plan_change_needs_payment`: they make it in the billing portal.
  `Authmk.Payments.resume/2` reverts a scheduled cancellation.

  ## Options

  #{NimbleOptions.docs(Authmk.Payments.Options.schema(Authmk.Plugins.Commet.Options.own()))}
  """

  use Authmk.Plugin

  @behaviour Authmk.Payments.Provider

  alias Authmk.{Background, Context, Error, Log}
  alias Authmk.Payments.{Client, Endpoints, Options, Reference, Schema, Store, Webhook}
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
    body = %{
      email: reference.email,
      externalId: Reference.external_id(reference),
      fullName: reference.name
    }

    with {:ok, %{"id" => id}} <- request(ctx, :post, "/customers", body, opts), do: {:ok, id}
  end

  @impl Authmk.Payments.Provider
  def checkout(ctx, checkout, opts) do
    with {:ok, seats} <- initial_seats(checkout.seats, opts[:seat_feature]) do
      body =
        %{
          customerId: checkout.customer_id,
          planId: checkout.price_id,
          successUrl: checkout.success_url,
          initialSeats: seats,
          customTrialDays: checkout.trial_days,
          skipTrial: not checkout.trial_allowed
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      create_subscription(ctx, checkout, body, opts)
    end
  end

  # Commet counts seats per seat feature: `%{"editor_seats" => 5}`.
  defp initial_seats(nil, _feature), do: {:ok, nil}
  defp initial_seats(seats, feature) when is_binary(feature), do: {:ok, %{feature => seats}}

  defp initial_seats(_seats, nil),
    do: {:error, Error.custom(:invalid_seats, 422, "This plan isn't sold by the seat")}

  defp create_subscription(ctx, checkout, body, opts) do
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
    path = subscription_path(subscription) <> "/cancel"

    with {:ok, object} <- request(ctx, :post, path, %{immediate: not at_period_end}, opts),
         do: {:ok, normalize(object)}
  end

  # Commet applies upgrades now and schedules downgrades for renewal; a
  # change the customer must pay for at a checkout can't be made here.
  @impl Authmk.Payments.Provider
  def change_plan(ctx, subscription, plan_id, opts) do
    path = subscription_path(subscription)

    case request(ctx, :post, path <> "/change-plan", %{newPlanId: plan_id}, opts) do
      {:ok, %{"outcome" => "requires_checkout"}} ->
        Log.warning("authmk Commet plan change needs the customer's checkout")

        {:error,
         Error.custom(
           :plan_change_needs_payment,
           402,
           "The customer must pay for this change: they can change plans in the billing portal"
         )}

      {:ok, _completed_or_scheduled} ->
        with {:ok, object} <- request(ctx, :get, path, nil, opts), do: {:ok, normalize(object)}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl Authmk.Payments.Provider
  def resume(ctx, subscription, opts) do
    with {:ok, object} <-
           request(ctx, :post, subscription_path(subscription) <> "/uncancel", %{}, opts),
         do: {:ok, normalize(object)}
  end

  defp subscription_path(subscription),
    do: "/subscriptions/" <> URI.encode(subscription.provider_subscription_id)

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
      # Commet may name the customer by the external id it was made with.
      reference_id: from_external(object["customerId"], :id),
      reference_type: from_external(object["customerId"], :type),
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

  defp from_external("user_" <> id, :id), do: id
  defp from_external("org_" <> id, :id), do: id
  defp from_external("user_" <> _id, :type), do: "user"
  defp from_external("org_" <> _id, :type), do: "organization"
  defp from_external(_customer_id, _part), do: nil

  # Commet's statuses, in Authmk.Payments' words.
  defp status("draft"), do: "incomplete"
  defp status("pending_payment"), do: "incomplete"
  defp status(status), do: status

  @doc """
  Whether a user (by id) or `{:organization, id}` may use `feature`
  (Commet's feature code), by its plan and usage. `false` when Commet
  can't be asked, or there's no customer yet.
  """
  @spec check(module(), Authmk.Payments.billed(), String.t()) :: {:ok, boolean()}
  def check(auth, reference, feature) do
    {ctx, opts} = server(auth)

    with %{customer_id: customer_id} <-
           Store.customer(ctx, provider(), Reference.from_app(reference)),
         query = URI.encode_query(customerId: customer_id),
         {:ok, %{"allowed" => true}} <-
           request(ctx, :get, "/feature-access/#{URI.encode(feature)}?" <> query, nil, opts) do
      {:ok, true}
    else
      _no -> {:ok, false}
    end
  end

  @doc "Records `value` units of usage of `feature` for a user or organization."
  @spec track(module(), Authmk.Payments.billed(), String.t(), number()) ::
          :ok | {:error, Error.t()}
  def track(auth, reference, feature, value \\ 1) do
    with {:ok, ctx, opts, customer_id} <- customer(auth, reference),
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
  @spec set_seats(module(), Authmk.Payments.billed(), String.t(), non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def set_seats(auth, reference, feature, count) do
    with {:ok, ctx, opts, customer_id} <- customer(auth, reference),
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

  defp customer(auth, reference) do
    {ctx, opts} = server(auth)

    case Store.customer(ctx, provider(), Reference.from_app(reference)) do
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
