defmodule Authmk.PaymentActionsTest do
  # Plans changed, subscriptions cancelled and resumed from server code
  # (Authmk.Payments.change_plan/4, cancel/3, resume/2) through each
  # provider's API, saved the way webhooks save them; and plans' prices
  # turned into monthly amounts.
  use Authmk.EmulationCase, async: true

  alias Authmk.Payments
  alias Authmk.Test.FakeBilling

  @secret "whsec_" <> Base.encode64("provider webhook key")
  @standard_key "provider webhook key"
  @period_end "2099-01-01T00:00:00Z"

  defmodule Hooks do
    @moduledoc false
    def created(subscription, _ctx), do: send(self(), {:hook, :created, subscription.plan})
    def updated(subscription, _ctx), do: send(self(), {:hook, :updated, subscription.plan})
    def canceled(subscription, _ctx), do: send(self(), {:hook, :canceled, subscription.plan})
  end

  for {name, {module, own}} <- [
        Stripe: {Authmk.Plugins.Stripe, []},
        Polar: {Authmk.Plugins.Polar, server: :sandbox},
        Dodo: {Authmk.Plugins.DodoPayments, environment: :test},
        Creem: {Authmk.Plugins.Creem, environment: :test},
        Chargebee: {Authmk.Plugins.Chargebee, site: "acme-test"},
        Commet: {Authmk.Plugins.Commet, []}
      ] do
    defmodule Module.concat(__MODULE__, name) do
      use Authmk,
        otp_app: :authmk,
        repo: Authmk.Test.Repo,
        base_url: "http://localhost:4000",
        background: :inline,
        rate_limit: [enabled: false],
        advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
        plugins: [
          Authmk.Plugins.EmailPassword,
          {module,
           [
             api_key: "provider-key",
             webhook_secret: "whsec_" <> Base.encode64("provider webhook key"),
             create_customer_on_sign_up: true,
             plans: [
               [
                 name: "pro",
                 id: "prod_pro",
                 annual_id: "prod_pro_year",
                 amount: 2_000,
                 annual_amount: 20_000,
                 currency: "USD"
               ],
               [name: "team", id: "prod_team", amount: 5_000, currency: "usd"],
               [name: "trial", id: "prod_trial", no_trial_id: "prod_trial_none"],
               [name: "free", id: "prod_free"]
             ],
             on_subscription_created: &Hooks.created/2,
             on_subscription_updated: &Hooks.updated/2,
             on_subscription_canceled: &Hooks.canceled/2
           ] ++ own}
        ]
    end
  end

  # A payment plugin of the app's own: Stripe's, without plan changes or
  # resuming, and with its own name.
  defmodule CancelOnly do
    @moduledoc false
    use Authmk.Plugin

    @behaviour Authmk.Payments.Provider

    alias Authmk.Plugins.Stripe

    defdelegate init(opts), to: Stripe
    defdelegate schema(opts), to: Stripe
    defdelegate endpoints(opts), to: Stripe
    defdelegate create_customer(ctx, reference, opts), to: Stripe
    defdelegate checkout(ctx, checkout, opts), to: Stripe
    defdelegate portal(ctx, portal, opts), to: Stripe
    defdelegate cancel(ctx, subscription, at_period_end, opts), to: Stripe
    defdelegate webhook(ctx, body, headers, opts), to: Stripe

    def provider, do: "cancel_only"
  end

  defmodule CancelOnlyAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, Authmk.PaymentActionsTest.Stripe}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {CancelOnly,
         api_key: "provider-key",
         webhook_secret: "whsec_x",
         plans: [[name: "pro", id: "prod_pro"]]}
      ]
  end

  defmodule NoBilling do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      plugins: [Authmk.Plugins.EmailPassword]
  end

  alias __MODULE__.{Chargebee, Commet, Creem, Dodo, Polar, Stripe}

  # Signs up (the customer is made then), lets the provider's webhook
  # report a subscription, and returns it as stored.
  defp subscribed(browser, auth, put_subscription, send_webhook) do
    {_browser, user} = sign_up(browser)
    put_subscription.()
    assert send_webhook.().status == 200
    assert_received {:hook, :created, _plan}
    [subscription] = Payments.subscriptions(auth, user["id"])
    subscription
  end

  # What every provider does: a new plan, a cancel at period end taken
  # back, then a cancel now that nothing undoes. Hooks fire as for webhooks.
  defp manage(auth, subscription) do
    id = subscription.id

    assert {:ok, %{plan: "team", price_id: "prod_team", status: "active"}} =
             Payments.change_plan(auth, id, "team")

    assert_received {:hook, :updated, "team"}
    refute_received {:hook, :canceled, _plan}

    assert {:ok, %{cancel_at_period_end: true, status: "active"}} = Payments.cancel(auth, id)
    assert_received {:hook, :updated, "team"}
    assert_received {:hook, :canceled, "team"}

    assert {:ok, %{cancel_at_period_end: false, status: "active", plan: "team"}} =
             Payments.resume(auth, id)

    assert_received {:hook, :updated, "team"}
    refute_received {:hook, :canceled, _plan}

    assert {:error, %{code: :not_scheduled_to_cancel}} = Payments.resume(auth, id)

    assert {:ok, %{status: "canceled"}} = Payments.cancel(auth, id, immediately: true)
    assert {:error, %{code: :subscription_canceled}} = Payments.resume(auth, id)
    assert {:error, %{code: :subscription_canceled}} = Payments.change_plan(auth, id, "pro")
    assert {:error, %{code: :subscription_canceled}} = Payments.cancel(auth, id)

    assert [%{status: "canceled", plan: "team"}] =
             Payments.subscriptions(auth, subscription.reference_id)
  end

  defp hex_webhook(auth, header, body) do
    signature = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)
    FakeBilling.webhook(auth, body, [{header, signature}])
  end

  describe "Stripe" do
    @describetag auth: Stripe

    setup do
      state =
        FakeBilling.stub(Stripe, fn
          "POST", "/v1/customers", _p, _s ->
            {200, %{"id" => "cus_1"}}

          "GET", "/v1/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}

          "POST", "/v1/subscriptions/" <> id, %{"items[0][price]" => price}, state ->
            Agent.update(
              state,
              &put_in(&1, [id, "items", "data", Access.at(0), "price"], %{"id" => price})
            )

            {200, FakeBilling.get(state, id)}

          "POST", "/v1/subscriptions/" <> id, %{"cancel_at_period_end" => value}, state ->
            Agent.update(state, &put_in(&1, [id, "cancel_at_period_end"], value == "true"))
            {200, FakeBilling.get(state, id)}

          "DELETE", "/v1/subscriptions/" <> id, _p, state ->
            Agent.update(state, &put_in(&1, [id, "status"], "canceled"))
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    defp stripe_subscription(state, seats \\ 1) do
      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customer" => "cus_1",
        "status" => "active",
        "cancel_at_period_end" => false,
        "metadata" => %{},
        "items" => %{
          "data" => [
            %{
              "id" => "si_1",
              "quantity" => seats,
              "price" => %{"id" => "prod_pro"},
              "current_period_end" => 4_070_908_800
            }
          ]
        }
      })
    end

    defp stripe_webhook do
      body =
        JSON.encode!(%{
          "type" => "customer.subscription.created",
          "data" => %{"object" => %{"id" => "sub_1"}}
        })

      FakeBilling.webhook(Stripe, body, [
        {"stripe-signature", FakeBilling.stripe_signature(body, @secret)}
      ])
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      subscription =
        subscribed(browser, Stripe, fn -> stripe_subscription(state) end, &stripe_webhook/0)

      assert subscription.plan == "pro"
      manage(Stripe, subscription)

      # The item's price changes, so its quantity stays.
      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1",
                       %{"items[0][id]" => "si_1", "items[0][price]" => "prod_team"} = form,
                       headers}

      refute Map.has_key?(form, "items[0][quantity]")
      assert {"authorization", "Bearer provider-key"} in headers

      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1",
                       %{"cancel_at_period_end" => "true"}, _h}

      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1",
                       %{"cancel_at_period_end" => "false"}, _h}

      assert_received {:billing_request, "DELETE", "/v1/subscriptions/sub_1", _p, _h}
    end

    test "annual prices, seats, and what a subscription brings in a month", %{
      browser: browser,
      provider: state
    } do
      subscription =
        subscribed(browser, Stripe, fn -> stripe_subscription(state, 3) end, &stripe_webhook/0)

      # The currency as configured ("USD"), kept lowercase.
      assert Payments.monthly_amount(Stripe, subscription) == {6_000, "usd"}

      assert {:ok, annual} = Payments.change_plan(Stripe, subscription.id, "pro", annual: true)
      assert %{plan: "pro", price_id: "prod_pro_year", seats: 3} = annual
      assert_received {:hook, :updated, "pro"}

      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1",
                       %{"items[0][price]" => "prod_pro_year"}, _h}

      assert Payments.monthly_amount(Stripe, annual) == {5_000, "usd"}

      # A year's price over 12 months, rounded: 20_000 / 12.
      assert Payments.monthly_amount(Stripe, %{annual | seats: nil}) == {1_667, "usd"}
      assert Payments.monthly_amount(Stripe, %{annual | seats: 1}) == {1_667, "usd"}

      # Plans without prices, and prices no plan has: nothing to count.
      assert Payments.monthly_amount(Stripe, %{annual | price_id: "prod_free"}) == nil
      assert Payments.monthly_amount(Stripe, %{annual | price_id: "price_unknown"}) == nil
      assert Payments.monthly_amount(Stripe, %{annual | price_id: nil}) == nil

      # Already on that price: the provider isn't asked.
      assert {:ok, %{price_id: "prod_pro_year"}} =
               Payments.change_plan(Stripe, subscription.id, :pro, annual: true)

      refute_received {:billing_request, "POST", "/v1/subscriptions/sub_1", _p, _h}
      refute_received {:hook, :updated, _plan}

      assert Payments.active?(annual)
      assert Payments.supports?(Stripe, :change_plan)
      assert Payments.supports?(Stripe, :resume)
      assert Payments.supports?(Stripe, :cancel)
      refute Payments.supports?(Stripe, :refund)
      assert {Authmk.Plugins.Stripe, opts} = Payments.provider(Stripe)
      assert [%{currency: "usd"} | _plans] = Enum.map(opts[:plans], &Map.new/1)
    end

    test "unknown subscriptions and plans, and a cancel not to take back", %{
      browser: browser,
      provider: state
    } do
      subscription =
        subscribed(browser, Stripe, fn -> stripe_subscription(state) end, &stripe_webhook/0)

      for id <- ["not-an-id", nil, Ecto.UUID.generate(), 0] do
        assert {:error, %{code: :subscription_not_found, status: 404}} =
                 Payments.cancel(Stripe, id)

        assert {:error, %{code: :subscription_not_found}} = Payments.resume(Stripe, id)

        assert {:error, %{code: :subscription_not_found}} =
                 Payments.change_plan(Stripe, id, "team")
      end

      assert {:error, %{code: :plan_not_found, message: "No such plan"}} =
               Payments.change_plan(Stripe, subscription.id, "enterprise")

      assert {:error, %{code: :plan_not_found, message: "This plan has no annual price"}} =
               Payments.change_plan(Stripe, subscription.id, "team", annual: true)

      assert {:error, %{code: :not_scheduled_to_cancel, status: 409}} =
               Payments.resume(Stripe, subscription.id)

      # Nothing asked of Stripe, nothing saved.
      refute_received {:billing_request, "POST", "/v1/subscriptions/sub_1", _p, _h}
      refute_received {:hook, :updated, _plan}
    end

    test "Stripe refusing: a generic error, and the subscription as it was", %{
      browser: browser,
      provider: state
    } do
      subscription =
        subscribed(browser, Stripe, fn -> stripe_subscription(state) end, &stripe_webhook/0)

      FakeBilling.stub(Stripe, fn
        "GET", "/v1/subscriptions/sub_1", _p, _s ->
          {200, %{"id" => "sub_1", "items" => %{"data" => [%{"id" => "si_1"}]}}}

        "POST", "/v1/subscriptions/sub_1", _p, _s ->
          {402, %{"error" => %{"code" => "card_declined", "message" => "acct_secret declined"}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, error} = Payments.change_plan(Stripe, subscription.id, "team")
          assert %{code: :payment_provider_error, message: "Stripe refused the request"} = error
        end)

      assert log =~ "card_declined"
      refute log =~ "acct_secret"

      assert [%{plan: "pro", price_id: "prod_pro"}] =
               Payments.subscriptions(Stripe, subscription.reference_id)

      refute_received {:hook, :updated, _plan}
    end

    test "a provider that can't, a subscription billed by another, no payment plugin", %{
      browser: browser,
      provider: state
    } do
      subscription =
        subscribed(browser, Stripe, fn -> stripe_subscription(state) end, &stripe_webhook/0)

      start_supervised!(CancelOnlyAuth)

      refute Payments.supports?(CancelOnlyAuth, :change_plan)
      refute Payments.supports?(CancelOnlyAuth, :resume)
      assert Payments.supports?(CancelOnlyAuth, :cancel)

      assert {:error,
              %{code: :not_supported, message: "The payment provider doesn't support this"}} =
               Payments.change_plan(CancelOnlyAuth, subscription.id, "pro")

      assert {:error, %{code: :not_supported}} = Payments.resume(CancelOnlyAuth, subscription.id)

      # Stripe's subscription, while the app bills with another plugin.
      assert {:error,
              %{code: :not_supported, message: "This subscription is billed by another provider"}} =
               Payments.cancel(CancelOnlyAuth, subscription.id)

      refute_received {:billing_request, "DELETE", _path, _p, _h}

      start_supervised!(NoBilling)
      assert Payments.provider(NoBilling) == nil
      assert Payments.monthly_amount(NoBilling, subscription) == nil
      refute Payments.supports?(NoBilling, :cancel)
      assert {:error, %{code: :feature_disabled}} = Payments.cancel(NoBilling, subscription.id)
      assert {:error, %{code: :feature_disabled}} = Payments.resume(NoBilling, subscription.id)

      assert {:error, %{code: :feature_disabled}} =
               Payments.change_plan(NoBilling, subscription.id, "pro")
    end
  end

  describe "Polar" do
    @describetag auth: Polar

    setup do
      state =
        FakeBilling.stub(Polar, fn
          "POST", "/v1/customers/", _p, _s ->
            {201, %{"id" => "cust_1"}}

          "GET", "/v1/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}

          "PATCH", "/v1/subscriptions/" <> id, %{"product_id" => product}, state ->
            Agent.update(state, &put_in(&1, [id, "product_id"], product))
            {200, FakeBilling.get(state, id)}

          "PATCH", "/v1/subscriptions/" <> id, %{"cancel_at_period_end" => value}, state ->
            Agent.update(state, &put_in(&1, [id, "cancel_at_period_end"], value))
            {200, FakeBilling.get(state, id)}

          "DELETE", "/v1/subscriptions/" <> id, _p, state ->
            Agent.update(state, &put_in(&1, [id, "status"], "canceled"))
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    defp polar_subscribed(browser, state, overrides \\ %{}) do
      put = fn ->
        FakeBilling.put(
          state,
          "sub_1",
          Map.merge(
            %{
              "id" => "sub_1",
              "customer_id" => "cust_1",
              "status" => "active",
              "product_id" => "prod_pro",
              "cancel_at_period_end" => false,
              "current_period_end" => @period_end
            },
            overrides
          )
        )
      end

      webhook = fn ->
        body = JSON.encode!(%{"type" => "subscription.created", "data" => %{"id" => "sub_1"}})
        FakeBilling.webhook(Polar, body, FakeBilling.standard_headers(body, @standard_key))
      end

      subscribed(browser, Polar, put, webhook)
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      manage(Polar, polar_subscribed(browser, state))

      assert_received {:billing_request, "PATCH", "/v1/subscriptions/sub_1",
                       %{"product_id" => "prod_team"} = change, headers}

      assert map_size(change) == 1
      assert {"authorization", "Bearer provider-key"} in headers

      assert_received {:billing_request, "PATCH", "/v1/subscriptions/sub_1",
                       %{"cancel_at_period_end" => false}, _h}
    end

    test "once a trial was had, a plan's product without one", %{
      browser: browser,
      provider: state
    } do
      subscription =
        polar_subscribed(browser, state, %{"trial_start" => "2026-09-01T00:00:00Z"})

      assert {:ok, %{plan: "trial", price_id: "prod_trial_none"}} =
               Payments.change_plan(Polar, subscription.id, "trial")
    end
  end

  describe "Dodo Payments" do
    @describetag auth: Dodo

    setup do
      %{provider: FakeBilling.stub(Dodo, &dodo_routes/4)}
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      put = fn ->
        FakeBilling.put(state, "sub_1", %{
          "subscription_id" => "sub_1",
          "customer" => %{"customer_id" => "cus_1"},
          "status" => "active",
          "product_id" => "prod_pro",
          "quantity" => 3,
          "cancel_at_next_billing_date" => false,
          "next_billing_date" => @period_end
        })
      end

      webhook = fn ->
        body =
          JSON.encode!(%{
            "type" => "subscription.active",
            "data" => %{"subscription_id" => "sub_1"}
          })

        FakeBilling.webhook(Dodo, body, FakeBilling.standard_headers(body, @standard_key))
      end

      manage(Dodo, subscribed(browser, Dodo, put, webhook))

      assert_received {:billing_request, "POST", "/subscriptions/sub_1/change-plan", change, _h}

      assert change == %{
               "product_id" => "prod_team",
               "quantity" => 3,
               "proration_billing_mode" => "prorated_immediately"
             }

      assert_received {:billing_request, "PATCH", "/subscriptions/sub_1",
                       %{"cancel_at_next_billing_date" => false}, _h}
    end
  end

  defp dodo_routes("POST", "/customers", _p, _s), do: {200, %{"customer_id" => "cus_1"}}

  defp dodo_routes("GET", "/subscriptions/" <> id, _p, state),
    do: {200, FakeBilling.get(state, id)}

  defp dodo_routes("POST", "/subscriptions/sub_1/change-plan", %{"product_id" => product}, state) do
    Agent.update(state, &put_in(&1, ["sub_1", "product_id"], product))
    {200, %{"payment_id" => nil}}
  end

  # Cancelled now (`status`), or at the next billing date, or not any more.
  defp dodo_routes("PATCH", "/subscriptions/sub_1", body, state) do
    Agent.update(state, &Map.update!(&1, "sub_1", fn sub -> Map.merge(sub, body) end))
    {200, %{}}
  end

  describe "Creem" do
    @describetag auth: Creem

    setup do
      state =
        FakeBilling.stub(Creem, fn
          "POST", "/v1/customers", _p, _s ->
            {200, %{"id" => "cust_1"}}

          "GET", "/v1/subscriptions", %{"subscription_id" => id}, state ->
            {200, FakeBilling.get(state, id)}

          "POST", "/v1/subscriptions/" <> path, params, state ->
            [id, action] = String.split(path, "/")

            Agent.update(
              state,
              &Map.update!(&1, id, fn sub -> creem_action(sub, action, params) end)
            )

            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      put = fn ->
        FakeBilling.put(state, "sub_1", %{
          "id" => "sub_1",
          "customer" => %{"id" => "cust_1"},
          "product" => %{"id" => "prod_pro"},
          "status" => "active",
          "current_period_end_date" => @period_end
        })
      end

      webhook = fn ->
        hex_webhook(
          Creem,
          "creem-signature",
          JSON.encode!(%{"eventType" => "subscription.active", "object" => %{"id" => "sub_1"}})
        )
      end

      manage(Creem, subscribed(browser, Creem, put, webhook))

      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1/upgrade",
                       %{"product_id" => "prod_team"}, headers}

      assert {"x-api-key", "provider-key"} in headers
      assert_received {:billing_request, "POST", "/v1/subscriptions/sub_1/resume", _p, _h}
    end
  end

  defp creem_action(sub, "upgrade", %{"product_id" => product}),
    do: Map.put(sub, "product", %{"id" => product})

  defp creem_action(sub, "cancel", %{"mode" => "scheduled"}),
    do: Map.put(sub, "status", "scheduled_cancel")

  defp creem_action(sub, "cancel", %{"mode" => "immediate"}),
    do: Map.put(sub, "status", "canceled")

  defp creem_action(sub, "resume", _params), do: Map.put(sub, "status", "active")

  describe "Chargebee" do
    @describetag auth: Chargebee

    setup do
      state =
        FakeBilling.stub(Chargebee, fn
          "POST", "/api/v2/customers", _p, _s ->
            {200, %{"customer" => %{"id" => "cb_1"}}}

          "GET", "/api/v2/subscriptions/" <> id, _p, state ->
            {200, %{"subscription" => FakeBilling.get(state, id)}}

          "POST", "/api/v2/subscriptions/" <> path, params, state ->
            [id, action] = String.split(path, "/")

            Agent.update(
              state,
              &Map.update!(&1, id, fn sub -> chargebee_action(sub, action, params) end)
            )

            {200, %{"subscription" => FakeBilling.get(state, id)}}
        end)

      %{provider: state}
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      put = fn ->
        FakeBilling.put(state, "sub_1", %{
          "id" => "sub_1",
          "customer_id" => "cb_1",
          "status" => "active",
          "current_term_end" => 4_070_908_800,
          "subscription_items" => [
            %{"item_price_id" => "prod_pro", "item_type" => "plan", "quantity" => 3}
          ]
        })
      end

      webhook = fn ->
        body =
          JSON.encode!(%{
            "event_type" => "subscription_created",
            "content" => %{"subscription" => %{"id" => "sub_1"}}
          })

        FakeBilling.webhook(Chargebee, body, [
          {"authorization", "Basic " <> Base.encode64(@secret)}
        ])
      end

      manage(Chargebee, subscribed(browser, Chargebee, put, webhook))

      assert_received {:billing_request, "POST", "/api/v2/subscriptions/sub_1/update_for_items",
                       change, _h}

      assert change == %{
               "subscription_items[item_price_id][0]" => "prod_team",
               "subscription_items[quantity][0]" => "3"
             }

      assert_received {:billing_request, "POST",
                       "/api/v2/subscriptions/sub_1/remove_scheduled_cancellation", _p, _h}
    end
  end

  defp chargebee_action(sub, "update_for_items", params) do
    item = %{
      "item_price_id" => params["subscription_items[item_price_id][0]"],
      "item_type" => "plan",
      "quantity" => String.to_integer(params["subscription_items[quantity][0]"] || "1")
    }

    Map.put(sub, "subscription_items", [item])
  end

  defp chargebee_action(sub, "cancel_for_items", %{"cancel_option" => "end_of_term"}),
    do: Map.put(sub, "status", "non_renewing")

  defp chargebee_action(sub, "cancel_for_items", %{"cancel_option" => "immediately"}),
    do: Map.put(sub, "status", "cancelled")

  defp chargebee_action(sub, "remove_scheduled_cancellation", _params),
    do: Map.put(sub, "status", "active")

  describe "Commet" do
    @describetag auth: Commet

    setup do
      state =
        FakeBilling.stub(Commet, fn
          "POST", "/api/v1/customers", _p, _s ->
            {201, %{"id" => "cus_1"}}

          "GET", "/api/v1/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}

          "POST", "/api/v1/subscriptions/" <> path, params, state ->
            [id, action] = String.split(path, "/")
            commet_action(state, id, action, params)
        end)

      %{provider: state}
    end

    defp commet_subscribed(browser, state) do
      put = fn ->
        FakeBilling.put(state, "sub_1", %{
          "id" => "sub_1",
          "customerId" => "cus_1",
          "plan" => %{"id" => "prod_pro"},
          "status" => "active",
          "cancelAtPeriodEnd" => false,
          "currentPeriod" => %{"start" => "2026-10-01T00:00:00Z", "end" => @period_end}
        })
      end

      webhook = fn ->
        hex_webhook(
          Commet,
          "x-commet-signature",
          JSON.encode!(%{
            "event" => "subscription.activated",
            "data" => %{"subscriptionId" => "sub_1"}
          })
        )
      end

      subscribed(browser, Commet, put, webhook)
    end

    test "change plan, cancel and resume", %{browser: browser, provider: state} do
      manage(Commet, commet_subscribed(browser, state))

      assert_received {:billing_request, "POST", "/api/v1/subscriptions/sub_1/change-plan",
                       %{"newPlanId" => "prod_team"}, headers}

      assert {"x-api-key", "provider-key"} in headers
      assert_received {:billing_request, "POST", "/api/v1/subscriptions/sub_1/uncancel", _p, _h}
    end

    test "a change the customer must pay for at a checkout is refused", %{
      browser: browser,
      provider: state
    } do
      subscription = commet_subscribed(browser, state)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %{code: :plan_change_needs_payment, status: 402}} =
                 Payments.change_plan(Commet, subscription.id, "pro", annual: true)
      end)

      assert [%{plan: "pro", price_id: "prod_pro"}] =
               Payments.subscriptions(Commet, subscription.reference_id)

      refute_received {:hook, :updated, _plan}
    end
  end

  defp commet_action(_state, _id, "change-plan", %{"newPlanId" => "prod_pro_year"}) do
    {200,
     %{
       "outcome" => "requires_checkout",
       "requiresCheckout" => true,
       "checkoutUrl" => "https://commet.co/checkout/2"
     }}
  end

  defp commet_action(state, id, "change-plan", %{"newPlanId" => plan}) do
    Agent.update(state, &put_in(&1, [id, "plan"], %{"id" => plan}))
    {200, %{"outcome" => "completed", "id" => "pc_1"}}
  end

  defp commet_action(state, id, "cancel", %{"immediate" => true}) do
    Agent.update(state, &put_in(&1, [id, "status"], "canceled"))
    {200, FakeBilling.get(state, id)}
  end

  defp commet_action(state, id, "cancel", %{"immediate" => false}) do
    Agent.update(state, &put_in(&1, [id, "cancelAtPeriodEnd"], true))
    {200, FakeBilling.get(state, id)}
  end

  defp commet_action(state, id, "uncancel", _params) do
    Agent.update(state, &put_in(&1, [id, "cancelAtPeriodEnd"], false))
    {200, FakeBilling.get(state, id)}
  end

  describe "plans' prices in config" do
    @describetag auth: NoBilling

    defp load(plans) do
      module = Module.concat(__MODULE__, "Plans#{System.unique_integer([:positive])}")

      Code.eval_quoted(
        quote do
          defmodule unquote(module) do
            use Authmk,
              otp_app: :authmk,
              repo: Authmk.Test.Repo,
              base_url: "http://localhost:4000",
              plugins: [
                {Authmk.Plugins.Stripe,
                 api_key: "k", webhook_secret: "w", plans: unquote(Macro.escape(plans))}
              ]
          end
        end
      )

      Authmk.Config.load(module)
    end

    test "prices are optional, and checked when given" do
      assert load([[name: "pro", id: "price_pro"]])

      config =
        load([
          [name: "pro", id: "p", annual_id: "y", amount: 0, annual_amount: 10, currency: "EUR"]
        ])

      assert [{Authmk.Plugins.Stripe, opts}] = config.plugins
      assert [plan] = opts[:plans]
      assert plan[:currency] == "eur"
      assert plan[:amount] == 0

      for {plans, message} <- [
            {[[name: "pro", id: "p", amount: -1, currency: "usd"]],
             ~r/amount must be a non-negative integer/},
            {[[name: "pro", id: "p", amount: 9.99, currency: "usd"]],
             ~r/amount must be a non-negative integer/},
            {[[name: "pro", id: "p", annual_id: "y", annual_amount: "100", currency: "usd"]],
             ~r/annual_amount must be a non-negative integer/},
            {[[name: "pro", id: "p", amount: 100]], ~r/need a currency/},
            {[[name: "pro", id: "p", amount: 100, currency: "dollars"]], ~r/ISO 4217/},
            {[[name: "pro", id: "p", amount: 100, currency: :usd]], ~r/ISO 4217/},
            {[[name: "pro", id: "p", annual_amount: 100, currency: "usd"]],
             ~r/annual_id, which is missing/},
            {["pro"], ~r/keyword list/}
          ] do
        assert_raise NimbleOptions.ValidationError, message, fn -> load(plans) end
      end
    end
  end
end
