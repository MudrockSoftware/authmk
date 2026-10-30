defmodule Authmk.PaymentProvidersTest do
  # Polar, Dodo Payments, Creem and Chargebee behind Authmk.Payments'
  # endpoints: each provider's requests, its webhook authentication, and
  # subscriptions read back from its API.
  use Authmk.EmulationCase, async: true

  alias Authmk.Payments
  alias Authmk.Plugins.Commet, as: CommetPlugin
  alias Authmk.Plugins.Polar
  alias Authmk.Test.{FakeBilling, Repo}

  for {name, plugin} <- [
        Polar: {Authmk.Plugins.Polar, server: :sandbox},
        Dodo: {Authmk.Plugins.DodoPayments, environment: :test},
        Creem: {Authmk.Plugins.Creem, environment: :test},
        Chargebee: {Authmk.Plugins.Chargebee, site: "acme-test"},
        Commet: {Authmk.Plugins.Commet, []}
      ] do
    {module, own} = plugin

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
             plans: [
               [name: "pro", id: "prod_pro", no_trial_id: "prod_pro_no_trial", trial_days: 7]
             ]
           ] ++ own}
        ]
    end
  end

  alias __MODULE__.{Chargebee, Commet, Creem, Dodo}

  @standard_key "provider webhook key"
  @secret "whsec_" <> Base.encode64("provider webhook key")

  defp signed_in(browser) do
    {browser, user} = sign_up(browser)
    {browser, user["id"]}
  end

  defp subscriptions(browser) do
    {_browser, conn} = get(browser, "/billing/subscriptions")
    json(conn)
  end

  describe "Polar" do
    @describetag auth: __MODULE__.Polar

    setup do
      state =
        FakeBilling.stub(__MODULE__.Polar, fn
          "POST", "/v1/customers/", _p, _s ->
            {201, %{"id" => "cust_1"}}

          "POST", "/v1/checkouts/", _p, _s ->
            {201, %{"url" => "https://sandbox.polar.sh/checkout/1"}}

          "POST", "/v1/customer-sessions/", _p, _s ->
            {201, %{"customer_portal_url" => "https://polar.sh/portal/1"}}

          "POST", "/v1/events/ingest", _p, _s ->
            {200, %{"inserted" => 1, "duplicates" => 0}}

          "GET", "/v1/customer-meters/", _p, _s ->
            {200, %{"items" => [%{"balance" => 42}]}}

          "GET", "/v1/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}

          "PATCH", "/v1/subscriptions/" <> id, %{"cancel_at_period_end" => true}, state ->
            Agent.update(state, &put_in(&1, [id, "cancel_at_period_end"], true))
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    test "checkout, a signed webhook, usage and meters", %{browser: browser, provider: state} do
      {browser, user_id} = signed_in(browser)
      {browser, conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})
      assert json(conn)["url"] == "https://sandbox.polar.sh/checkout/1"

      assert_received {:billing_request, "POST", "/v1/customers/", %{"external_id" => ^user_id},
                       _h}

      assert_received {:billing_request, "POST", "/v1/checkouts/", checkout, headers}
      assert checkout["products"] == ["prod_pro"]
      assert checkout["allow_trial"] == true
      assert {"authorization", "Bearer provider-key"} in headers

      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customer_id" => "cust_1",
        "status" => "active",
        "product_id" => "prod_pro",
        "cancel_at_period_end" => false,
        "current_period_end" => "2099-01-01T00:00:00Z"
      })

      # Signed the way older Polar secrets are: the whole string is the key.
      body = JSON.encode!(%{"type" => "subscription.active", "data" => %{"id" => "sub_1"}})

      conn =
        FakeBilling.webhook(__MODULE__.Polar, body, FakeBilling.standard_headers(body, @secret))

      assert conn.status == 200
      assert [%{"plan" => "pro", "active" => true, "id" => id}] = subscriptions(browser)

      {browser, conn} = post(browser, "/billing/cancel", %{subscription_id: id})
      assert json(conn)["cancel_at_period_end"]

      {_browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
      assert json(conn)["url"] == "https://polar.sh/portal/1"

      assert :ok = Polar.track(__MODULE__.Polar, user_id, "ai_tokens", %{tokens: 1200})
      assert_received {:billing_request, "POST", "/v1/events/ingest", %{"events" => [event]}, _h}

      assert event == %{
               "name" => "ai_tokens",
               "external_customer_id" => user_id,
               "metadata" => %{"tokens" => 1200}
             }

      assert {:ok, [%{"balance" => 42}]} = Polar.meters(__MODULE__.Polar, user_id)
    end

    test "newer secrets sign with the decoded key; others are refused", %{provider: state} do
      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customer_id" => "unknown",
        "status" => "active"
      })

      body = JSON.encode!(%{"type" => "subscription.updated", "data" => %{"id" => "sub_1"}})

      assert FakeBilling.webhook(
               __MODULE__.Polar,
               body,
               FakeBilling.standard_headers(body, @standard_key)
             ).status == 200

      assert FakeBilling.webhook(
               __MODULE__.Polar,
               body,
               FakeBilling.standard_headers(body, "nope")
             ).status == 400

      stale =
        FakeBilling.standard_headers(
          body,
          @standard_key,
          "msg_1",
          System.system_time(:second) - 900
        )

      assert FakeBilling.webhook(__MODULE__.Polar, body, stale).status == 400
    end
  end

  describe "Dodo Payments" do
    @describetag auth: Dodo

    setup do
      state =
        FakeBilling.stub(Dodo, fn
          "POST", "/customers", _p, _s ->
            {200, %{"customer_id" => "cus_1"}}

          "POST", "/checkouts", _p, _s ->
            {200,
             %{
               "session_id" => "cks_1",
               "checkout_url" => "https://test.checkout.dodopayments.com/1"
             }}

          "POST", "/customers/cus_1/customer-portal/session", _p, _s ->
            {200, %{"link" => "https://customer.dodopayments.com/1"}}

          "PATCH", "/subscriptions/" <> id, body, state ->
            Agent.update(state, &Map.update!(&1, id, fn sub -> Map.merge(sub, body) end))
            {200, %{}}

          "GET", "/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    test "checkout, trials once, a signed webhook", %{browser: browser, provider: state} do
      {browser, _user_id} = signed_in(browser)
      {browser, _conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})
      assert_received {:billing_request, "POST", "/checkouts", checkout, _h}
      assert checkout["product_cart"] == [%{"product_id" => "prod_pro", "quantity" => 1}]
      assert checkout["subscription_data"] == %{"trial_period_days" => 7}
      assert checkout["return_url"] == "http://localhost:4000/done"

      FakeBilling.put(state, "sub_1", %{
        "subscription_id" => "sub_1",
        "customer" => %{"customer_id" => "cus_1"},
        "status" => "cancelled",
        "product_id" => "prod_pro",
        "next_billing_date" => "2099-01-01T00:00:00Z"
      })

      body =
        JSON.encode!(%{
          "type" => "subscription.cancelled",
          "data" => %{"subscription_id" => "sub_1"}
        })

      conn = FakeBilling.webhook(Dodo, body, FakeBilling.standard_headers(body, @standard_key))
      assert conn.status == 200
      assert [%{"status" => "canceled", "active" => false}] = subscriptions(browser)

      # The same body, signed with the undecoded secret: not Dodo's way.
      assert FakeBilling.webhook(Dodo, body, FakeBilling.standard_headers(body, @secret)).status ==
               400

      {browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
      assert json(conn)["url"] == "https://customer.dodopayments.com/1"

      # Back on; then cancelled now, and at period end, through the endpoint.
      FakeBilling.put(state, "sub_1", %{FakeBilling.get(state, "sub_1") | "status" => "active"})
      [%{"id" => id}] = subscriptions(browser)

      {browser, conn} =
        post(browser, "/billing/cancel", %{subscription_id: id, immediately: true})

      assert json(conn)["status"] == "canceled"

      assert_received {:billing_request, "PATCH", "/subscriptions/sub_1",
                       %{"status" => "cancelled"}, _h}

      {_browser, _conn} = post(browser, "/billing/cancel", %{subscription_id: id})

      assert_received {:billing_request, "PATCH", "/subscriptions/sub_1",
                       %{"cancel_at_next_billing_date" => true}, _h}
    end
  end

  describe "Creem" do
    @describetag auth: Creem

    setup do
      state =
        FakeBilling.stub(Creem, fn
          "POST", "/v1/customers", _p, _s ->
            {200, %{"id" => "cust_1"}}

          "POST", "/v1/checkouts", _p, _s ->
            {200, %{"id" => "ch_1", "checkout_url" => "https://creem.io/checkout/1"}}

          "POST", "/v1/customers/billing", _p, _s ->
            {200, %{"customer_portal_link" => "https://creem.io/portal/1"}}

          "POST", "/v1/subscriptions/" <> rest, %{"mode" => mode}, state ->
            id = String.replace_suffix(rest, "/cancel", "")
            status = if mode == "scheduled", do: "scheduled_cancel", else: "canceled"
            Agent.update(state, &put_in(&1, [id, "status"], status))
            {200, %{}}

          "GET", "/v1/subscriptions", %{"subscription_id" => id}, state ->
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    defp creem_webhook(body, secret \\ @secret) do
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      FakeBilling.webhook(Creem, body, [{"creem-signature", signature}])
    end

    test "a trial once: after it, the product without one", %{browser: browser, provider: state} do
      {browser, user_id} = signed_in(browser)
      {browser, _conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})

      assert_received {:billing_request, "POST", "/v1/checkouts", %{"product_id" => "prod_pro"},
                       _h}

      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customer" => %{"id" => "cust_1"},
        "product" => %{"id" => "prod_pro"},
        "status" => "trialing",
        "current_period_end_date" => "2099-01-01T00:00:00Z"
      })

      # Creem's payload only names the subscription: what it says is read from Creem.
      body =
        JSON.encode!(%{
          "id" => "evt_1",
          "eventType" => "subscription.trialing",
          "object" => %{"id" => "sub_1", "status" => "active"}
        })

      assert creem_webhook(body).status == 200
      assert [%{"status" => "trialing"}] = subscriptions(browser)

      # Forged: refused.
      assert creem_webhook(body, "another secret").status == 400

      # Trial over, cancelled; back again: no second trial.
      FakeBilling.put(state, "sub_1", %{FakeBilling.get(state, "sub_1") | "status" => "canceled"})

      assert creem_webhook(
               JSON.encode!(%{
                 "eventType" => "subscription.canceled",
                 "object" => %{"id" => "sub_1"}
               })
             ).status == 200

      {_browser, _conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})

      assert_received {:billing_request, "POST", "/v1/checkouts",
                       %{"product_id" => "prod_pro_no_trial"}, _h}

      refute Payments.active_subscription(Creem, user_id)

      # Cancelled through the endpoint, scheduled: still active until it ends.
      FakeBilling.put(state, "sub_1", %{FakeBilling.get(state, "sub_1") | "status" => "active"})
      [%{"id" => id}] = subscriptions(browser)
      {browser, conn} = post(browser, "/billing/cancel", %{subscription_id: id})
      assert %{"status" => "active", "cancel_at_period_end" => true} = json(conn)

      {browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
      assert json(conn)["url"] == "https://creem.io/portal/1"

      {_browser, conn} = post(browser, "/billing/checkout", %{plan: "missing", success_url: "/"})
      assert json(conn)["error"]["code"] == "plan_not_found"
    end
  end

  describe "Chargebee" do
    @describetag auth: Chargebee

    setup do
      state =
        FakeBilling.stub(Chargebee, fn
          "POST", "/api/v2/customers", _p, _s ->
            {200, %{"customer" => %{"id" => "cb_cust_1"}}}

          "POST", "/api/v2/hosted_pages/checkout_new_for_items", _p, _s ->
            {200, %{"hosted_page" => %{"url" => "https://acme-test.chargebee.com/pages/1"}}}

          "POST", "/api/v2/portal_sessions", _p, _s ->
            {200,
             %{"portal_session" => %{"access_url" => "https://acme-test.chargebee.com/portal/1"}}}

          "GET", "/api/v2/subscriptions/" <> id, _p, state ->
            {200, %{"subscription" => FakeBilling.get(state, id)}}

          "POST", "/api/v2/subscriptions/" <> rest, %{"cancel_option" => option}, state ->
            id = String.replace_suffix(rest, "/cancel_for_items", "")
            status = if option == "end_of_term", do: "non_renewing", else: "cancelled"
            Agent.update(state, &put_in(&1, [id, "status"], status))
            {200, %{"subscription" => FakeBilling.get(state, id)}}
        end)

      %{provider: state}
    end

    defp chargebee_webhook(body, credentials) do
      FakeBilling.webhook(Chargebee, body, [
        {"authorization", "Basic " <> Base.encode64(credentials)}
      ])
    end

    test "hosted checkout, Basic-auth webhooks, the portal", %{browser: browser, provider: state} do
      {browser, _user_id} = signed_in(browser)
      {browser, conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})
      assert json(conn)["url"] == "https://acme-test.chargebee.com/pages/1"

      assert_received {:billing_request, "POST", "/api/v2/customers", _p, headers}
      assert {"authorization", "Basic " <> Base.encode64("provider-key:")} in headers

      assert_received {:billing_request, "POST", "/api/v2/hosted_pages/checkout_new_for_items",
                       form, _h}

      assert form["subscription_items[item_price_id][0]"] == "prod_pro"
      assert form["customer[id]"] == "cb_cust_1"
      assert String.to_integer(form["subscription[trial_end]"]) > System.system_time(:second)

      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customer_id" => "cb_cust_1",
        "status" => "non_renewing",
        "current_term_end" => 4_070_908_800,
        "subscription_items" => [
          %{"item_price_id" => "prod_pro", "item_type" => "plan", "quantity" => 1}
        ]
      })

      body =
        JSON.encode!(%{
          "id" => "ev_1",
          "event_type" => "subscription_cancellation_scheduled",
          "content" => %{"subscription" => %{"id" => "sub_1"}}
        })

      assert chargebee_webhook(body, "wrong:creds").status == 400
      assert chargebee_webhook(body, @secret).status == 200

      assert [%{"status" => "active", "cancel_at_period_end" => true, "plan" => "pro"}] =
               subscriptions(browser)

      {browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
      assert json(conn)["url"] == "https://acme-test.chargebee.com/portal/1"

      [%{"id" => id}] = subscriptions(browser)

      {_browser, conn} =
        post(browser, "/billing/cancel", %{subscription_id: id, immediately: true})

      assert json(conn)["status"] == "canceled"
    end
  end

  describe "Commet" do
    @describetag auth: Commet

    setup do
      state =
        FakeBilling.stub(Commet, fn
          "POST", "/api/v1/customers", _p, _s ->
            {201, %{"id" => "cus_1"}}

          "POST", "/api/v1/subscriptions", _p, _s ->
            {201, %{"id" => "sub_1", "checkoutUrl" => "https://commet.co/checkout/1"}}

          "GET", "/api/v1/subscriptions/" <> id, _p, state ->
            {200, FakeBilling.get(state, id)}

          "GET", "/api/v1/feature-access/api_calls", _p, _s ->
            {200, %{"code" => "api_calls", "allowed" => true}}

          "GET", "/api/v1/feature-access/" <> _other, _p, _s ->
            {500, %{}}

          "POST", "/api/v1/usage/events", _p, _s ->
            {201, %{"id" => "ue_1"}}

          "PUT", "/api/v1/seats", _p, _s ->
            {200, %{"id" => "se_1"}}

          "POST", "/api/v1/subscriptions/" <> rest, %{"immediate" => immediate}, state ->
            id = String.replace_suffix(rest, "/cancel", "")

            change =
              if immediate, do: %{"status" => "canceled"}, else: %{"cancelAtPeriodEnd" => true}

            Agent.update(state, &Map.update!(&1, id, fn sub -> Map.merge(sub, change) end))
            {200, FakeBilling.get(state, id)}
        end)

      %{provider: state}
    end

    defp commet_webhook(body, secret \\ @secret) do
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      FakeBilling.webhook(Commet, body, [{"x-commet-signature", signature}])
    end

    test "checkout, a re-read webhook, access, usage and seats", %{
      browser: browser,
      provider: state
    } do
      {browser, user_id} = signed_in(browser)

      {browser, conn} =
        post(browser, "/billing/checkout", %{plan: "pro", seats: 3, success_url: "/done"})

      assert json(conn)["url"] == "https://commet.co/checkout/1"

      assert_received {:billing_request, "POST", "/api/v1/customers", %{"externalId" => ^user_id},
                       headers}

      assert {"x-api-key", "provider-key"} in headers
      assert {"commet-version", "2026-08-27"} in headers
      assert_received {:billing_request, "POST", "/api/v1/subscriptions", checkout, _h}

      assert %{
               "planId" => "prod_pro",
               "initialSeats" => 3,
               "customTrialDays" => 7,
               "skipTrial" => false
             } = checkout

      FakeBilling.put(state, "sub_1", %{
        "id" => "sub_1",
        "customerId" => "cus_1",
        "plan" => %{"id" => "prod_pro"},
        "status" => "trialing",
        "cancelAtPeriodEnd" => false,
        "currentPeriod" => %{"start" => "2026-10-01T00:00:00Z", "end" => "2099-01-01T00:00:00Z"}
      })

      # The payload names the subscription; its state is read from Commet.
      body =
        JSON.encode!(%{
          "id" => "evt_1",
          "event" => "subscription.activated",
          "data" => %{"subscriptionId" => "sub_1", "status" => "canceled"}
        })

      assert commet_webhook(body, "another secret").status == 400
      assert commet_webhook(body).status == 200

      assert [%{"plan" => "pro", "status" => "trialing", "active" => true}] =
               subscriptions(browser)

      assert {:ok, true} = CommetPlugin.check(Commet, user_id, "api_calls")
      # Commet failing: no access.
      assert {:ok, false} = CommetPlugin.check(Commet, user_id, "exports")
      assert {:ok, false} = CommetPlugin.check(Commet, "nobody", "api_calls")

      assert :ok = CommetPlugin.track(Commet, user_id, "api_calls", 5)

      assert_received {:billing_request, "POST", "/api/v1/usage/events",
                       %{"featureCode" => "api_calls", "customerId" => "cus_1", "value" => 5}, _h}

      assert :ok = CommetPlugin.set_seats(Commet, user_id, "editors", 12)

      assert_received {:billing_request, "PUT", "/api/v1/seats",
                       %{"count" => 12, "customerId" => "cus_1"}, _h}

      [%{"id" => id}] = subscriptions(browser)
      {browser, conn} = post(browser, "/billing/cancel", %{subscription_id: id})
      assert json(conn)["cancel_at_period_end"] == true

      # Had a trial: the next checkout skips it.
      Repo.update_all("subscriptions", set: [status: "canceled"])
      {_browser, _conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})

      assert_received {:billing_request, "POST", "/api/v1/subscriptions",
                       %{"skipTrial" => true} = again, _h}

      refute Map.has_key?(again, "customTrialDays")
    end
  end
end
