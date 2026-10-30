defmodule Authmk.StripeTest do
  # Subscriptions with Stripe, end to end: Checkout, webhooks (re-read from
  # Stripe), the portal, cancelling, trials once, organizations.
  use Authmk.EmulationCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Authmk.Payments
  alias Authmk.Plugins.Organization
  alias Authmk.Test.{FakeBilling, Repo}

  @secret "whsec_test_secret"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.Stripe,
         api_key: "sk_test_123",
         webhook_secret: "whsec_test_secret",
         automatic_tax: true,
         create_customer_on_sign_up: true,
         organizations: true,
         plans: [
           [
             name: "pro",
             id: "price_pro",
             annual_id: "price_pro_year",
             trial_days: 14,
             limits: %{projects: 20}
           ],
           [name: "team", id: "price_team", limits: %{projects: true}],
           [name: "gone", id: "price_gone"]
         ],
         on_subscription_created: &__MODULE__.created/2,
         on_subscription_canceled: &__MODULE__.canceled/2,
         on_trial_started: &__MODULE__.trial_started/2}
      ]

    def created(subscription, _ctx), do: send(self(), {:hook, :created, subscription.plan})
    def canceled(subscription, _ctx), do: send(self(), {:hook, :canceled, subscription.plan})

    def trial_started(subscription, _ctx),
      do: send(self(), {:hook, :trial_started, subscription.plan})
  end

  @moduletag auth: Auth

  # Stripe: customers, sessions, and subscriptions it keeps.
  setup do
    state =
      FakeBilling.stub(Auth, fn
        "POST", "/v1/customers", _params, _state ->
          {200, %{"id" => "cus_#{System.unique_integer([:positive])}"}}

        "POST", "/v1/checkout/sessions", %{"line_items[0][price]" => "price_gone"}, _params ->
          {400,
           %{
             "error" => %{
               "code" => "resource_missing",
               "message" => "No such price: price_gone in acct_secret"
             }
           }}

        "POST", "/v1/checkout/sessions", _params, _state ->
          {200, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/pay/cs_1"}}

        "POST", "/v1/billing_portal/sessions", _params, _state ->
          {200, %{"url" => "https://billing.stripe.com/p/session/1"}}

        "GET", "/v1/subscriptions/" <> id, _params, state ->
          {200, FakeBilling.get(state, id)}

        "POST", "/v1/subscriptions/" <> id, %{"cancel_at_period_end" => "true"}, state ->
          Agent.update(
            state,
            &Map.update!(&1, id, fn s -> Map.put(s, "cancel_at_period_end", true) end)
          )

          {200, FakeBilling.get(state, id)}

        "DELETE", "/v1/subscriptions/" <> id, _params, state ->
          Agent.update(state, &Map.update!(&1, id, fn s -> Map.put(s, "status", "canceled") end))
          {200, FakeBilling.get(state, id)}
      end)

    %{stripe: state}
  end

  defp subscription(id, customer, reference_id, overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "id" => id,
        "object" => "subscription",
        "customer" => customer,
        "status" => "trialing",
        "cancel_at_period_end" => false,
        "trial_start" => now,
        "trial_end" => now + 14 * 86_400,
        "metadata" => %{"reference_id" => reference_id, "reference_type" => "user"},
        "items" => %{
          "data" => [
            %{
              "id" => "si_1",
              "quantity" => 1,
              "price" => %{"id" => "price_pro"},
              "current_period_start" => now,
              "current_period_end" => now + 30 * 86_400
            }
          ]
        }
      },
      overrides
    )
  end

  defp send_event(type, object, secret \\ @secret, timestamp \\ System.system_time(:second)) do
    body = JSON.encode!(%{"id" => "evt_1", "type" => type, "data" => %{"object" => object}})

    FakeBilling.webhook(Auth, body, [
      {"stripe-signature", FakeBilling.stripe_signature(body, secret, timestamp)}
    ])
  end

  defp customer_id(user_id) do
    Repo.one!(
      from(c in "billing_customers",
        where: c.reference_id == ^user_id,
        select: c.customer_id
      )
    )
  end

  test "checkout, the webhook, then what the user has", %{browser: browser, stripe: stripe} do
    {browser, user} = sign_up(browser)

    # The customer was made at sign-up.
    assert_received {:billing_request, "POST", "/v1/customers", %{"email" => "ada@example.com"},
                     headers}

    assert {"authorization", "Bearer sk_test_123"} in headers
    customer = customer_id(user["id"])

    {browser, conn} =
      post(browser, "/billing/checkout", %{plan: "pro", success_url: "/billing/done"})

    assert json(conn) == %{"url" => "https://checkout.stripe.com/c/pay/cs_1", "redirect" => true}

    assert_received {:billing_request, "POST", "/v1/checkout/sessions", form, _headers}
    assert form["customer"] == customer
    assert form["line_items[0][price]"] == "price_pro"
    assert form["subscription_data[trial_period_days]"] == "14"
    assert form["subscription_data[metadata][reference_id]"] == user["id"]
    assert form["success_url"] == "http://localhost:4000/billing/done"
    assert form["automatic_tax[enabled]"] == "true"
    assert form["customer_update[address]"] == "auto"

    # Stripe tells us; we read the subscription from Stripe.
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, user["id"]))
    conn = send_event("customer.subscription.created", %{"id" => "sub_1"})
    assert conn.status == 200
    assert_received {:billing_request, "GET", "/v1/subscriptions/sub_1", _params, _headers}
    assert_received {:hook, :created, "pro"}
    assert_received {:hook, :trial_started, "pro"}

    {browser, conn} = get(browser, "/billing/subscriptions")
    assert [%{"plan" => "pro", "status" => "trialing", "active" => true, "id" => id}] = json(conn)

    assert Payments.allowed?(Auth, user["id"], :projects, 20)
    refute Payments.allowed?(Auth, user["id"], :projects, 21)
    refute Payments.allowed?(Auth, user["id"], :seats)

    # The same plan again: no.
    {browser, conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/"})
    assert json(conn)["error"]["code"] == "already_subscribed"

    {browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
    assert json(conn)["url"] == "https://billing.stripe.com/p/session/1"

    # Cancelled at period end: still active until then.
    {browser, conn} = post(browser, "/billing/cancel", %{subscription_id: id})
    assert json(conn)["cancel_at_period_end"] == true
    assert json(conn)["active"] == true
    assert_received {:hook, :canceled, "pro"}

    # It ends; a new subscription gets no second trial.
    FakeBilling.put(
      stripe,
      "sub_1",
      subscription("sub_1", customer, user["id"], %{"status" => "canceled"})
    )

    send_event("customer.subscription.deleted", %{"id" => "sub_1"})
    assert Payments.active_subscription(Auth, user["id"]) == nil

    {_browser, _conn} =
      post(browser, "/billing/checkout", %{plan: "pro", success_url: "/", annual: true})

    assert_received {:billing_request, "POST", "/v1/checkout/sessions", form, _headers}
    assert form["line_items[0][price]"] == "price_pro_year"
    refute Map.has_key?(form, "subscription_data[trial_period_days]")
  end

  test "webhooks that aren't Stripe's change nothing", %{browser: browser, stripe: stripe} do
    {_browser, user} = sign_up(browser)
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer_id(user["id"]), user["id"]))

    assert send_event("customer.subscription.created", %{"id" => "sub_1"}, "whsec_other").status ==
             400

    old = System.system_time(:second) - 600

    assert send_event("customer.subscription.created", %{"id" => "sub_1"}, @secret, old).status ==
             400

    unsigned = FakeBilling.webhook(Auth, ~s({"type":"customer.subscription.created"}), [])
    assert unsigned.status == 400

    assert Payments.subscriptions(Auth, user["id"]) == []
  end

  test "organizations subscribe through their owners and admins", %{
    browser: browser,
    stripe: stripe
  } do
    {owner, owner_user} = sign_up(browser, %{email: "owner@example.com"})
    {member, member_user} = sign_up(browser, %{email: "member@example.com"})

    {:ok, organization} =
      Authmk.Store.insert(Authmk.Context.new(Auth.config()), :organization, %{
        name: "Acme",
        slug: "acme"
      })

    {:ok, _} = Organization.add_member(Auth, organization.id, owner_user["id"], "owner")
    {:ok, _} = Organization.add_member(Auth, organization.id, member_user["id"], "member")
    org_id = to_string(organization.id)

    {_member, conn} =
      post(member, "/billing/checkout", %{plan: "team", reference_id: org_id, success_url: "/"})

    assert json(conn)["error"]["code"] == "forbidden"

    {owner, conn} =
      post(owner, "/billing/checkout", %{
        plan: "team",
        reference_id: org_id,
        seats: 5,
        success_url: "/"
      })

    assert json(conn)["redirect"]
    assert_received {:billing_request, "POST", "/v1/checkout/sessions", form, _headers}
    assert form["line_items[0][quantity]"] == "5"
    assert form["subscription_data[metadata][reference_type]"] == "organization"

    team =
      subscription("sub_team", form["customer"], org_id, %{
        "status" => "active",
        "metadata" => %{"reference_id" => org_id, "reference_type" => "organization"},
        "items" => %{
          "data" => [%{"id" => "si_2", "quantity" => 5, "price" => %{"id" => "price_team"}}]
        }
      })

    FakeBilling.put(stripe, "sub_team", team)

    send_event("checkout.session.completed", %{
      "id" => "cs_1",
      "mode" => "subscription",
      "subscription" => "sub_team"
    })

    assert Payments.allowed?(Auth, {:organization, org_id}, :projects, 1000)
    # The organization's plan, not its owner's.
    refute Payments.allowed?(Auth, owner_user["id"], :projects, 1)
    {_owner, conn} = get(owner, "/billing/subscriptions", %{reference_id: org_id})
    assert [%{"plan" => "team", "seats" => 5, "reference_type" => "organization"}] = json(conn)
  end

  test "Stripe refusing: a generic error, nothing of Stripe's passed on", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {_browser, conn} = post(browser, "/billing/checkout", %{plan: "gone", success_url: "/"})

        assert conn.status == 502
        assert json(conn)["error"]["code"] == "payment_provider_error"
        assert json(conn)["error"]["message"] == "Stripe refused the request"
        refute conn.resp_body =~ "acct_secret"
        refute conn.resp_body =~ "resource_missing"
      end)

    # Stripe's code is in the logs, for whoever runs the app.
    assert log =~ "resource_missing"

    {_browser, conn} =
      post(browser, "/billing/checkout", %{plan: "pro", success_url: "https://evil.example/"})

    assert json(conn)["error"]["code"] == "invalid_callback_url"
  end
end
