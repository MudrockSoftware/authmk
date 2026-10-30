defmodule Authmk.DashboardPaymentsTest do
  # Earnings from the subscriptions webhooks stored and the plans' prices,
  # and subscriptions changed through the provider (a fake Stripe).
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.{Context, Store, Testing}
  alias Authmk.Test.FakeBilling

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
        Authmk.Plugins.Admin,
        Authmk.Plugins.AuditLog,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.Stripe,
         api_key: "sk_test",
         webhook_secret: "whsec_test",
         organizations: true,
         plans: [
           [
             name: "pro",
             id: "price_pro",
             annual_id: "price_pro_year",
             amount: 2_000,
             annual_amount: 24_000,
             currency: "usd"
           ],
           [name: "team", id: "price_team", amount: 5_000, currency: "eur"],
           [name: "legacy", id: "price_legacy"]
         ]}
      ]
  end

  @moduletag auth: Auth

  setup do
    admin = Testing.create_user(Auth, email: "admin@example.com", role: "admin")
    ada = Testing.create_user(Auth, email: "ada@example.com")
    ctx = Context.new(Auth.config())

    subscription = fn id, price, attrs ->
      {:ok, subscription} =
        Store.insert(
          ctx,
          :subscription,
          Map.merge(
            %{
              provider: "stripe",
              reference_id: to_string(ada.id),
              reference_type: "user",
              customer_id: "cus_1",
              provider_subscription_id: id,
              price_id: price,
              plan: nil,
              status: "active",
              period_end: DateTime.add(DateTime.utc_now(), 86_400 * 20)
            },
            attrs
          )
        )

      subscription
    end

    %{
      admin: admin,
      ada: ada,
      pro: subscription.("sub_pro", "price_pro", %{plan: "pro", seats: 2}),
      yearly: subscription.("sub_year", "price_pro_year", %{plan: "pro"}),
      team: subscription.("sub_team", "price_team", %{plan: "team"}),
      legacy: subscription.("sub_legacy", "price_legacy", %{plan: "legacy"}),
      ended:
        subscription.("sub_old", "price_pro", %{
          plan: "pro",
          status: "canceled",
          canceled_at: DateTime.utc_now()
        })
    }
  end

  test "earnings: recurring revenue by currency, plan and provider", %{admin: admin} do
    {200, payments} = get_json(Auth, "payments", admin)
    assert payments["provider"] == "stripe"
    assert payments["supports"] == %{"cancel" => true, "change_plan" => true, "resume" => true}

    assert %{"name" => "pro", "amount" => 2000, "annual_amount" => 24_000, "annual" => true} =
             hd(payments["plans"])

    earnings = payments["earnings"]
    assert earnings["active_subscriptions"] == 4
    assert earnings["unpriced_subscriptions"] == 1

    # Pro: 2 seats at 20 USD, and a year at 240 USD (20 a month). Team: 50 EUR.
    assert %{"currency" => "usd", "monthly" => 6_000, "yearly" => 72_000, "subscriptions" => 2} in earnings[
             "recurring_revenue"
           ]

    assert %{"currency" => "eur", "monthly" => 5_000} =
             Enum.find(earnings["recurring_revenue"], &(&1["currency"] == "eur"))

    assert %{"plan" => "pro", "provider" => "stripe", "monthly" => 6_000} =
             Enum.find(earnings["by_plan"], &(&1["plan"] == "pro"))

    assert earnings["by_status"] == %{"active" => 4, "canceled" => 1}

    # A plan without a price is left out, and the health checks say so.
    {200, %{"checks" => checks}} = get_json(Auth, "health", admin)
    assert %{"status" => "warning"} = Enum.find(checks, &(&1["name"] == "stripe plans"))
    assert %{"status" => "ok"} = Enum.find(checks, &(&1["name"] == "stripe webhooks"))
    assert List.last(earnings["new_subscriptions"])["count"] == 5
    assert List.last(earnings["cancellations"])["count"] == 1
  end

  test "subscriptions, listed with whose they are", %{admin: admin} do
    {200, %{"subscriptions" => subscriptions}} =
      get_json(Auth, "payments/subscriptions?plan=pro", admin)

    assert length(subscriptions) == 3
    assert Enum.all?(subscriptions, &(&1["reference_name"] == "ada@example.com"))

    {200, %{"subscriptions" => [canceled]}} =
      get_json(Auth, "payments/subscriptions?status=canceled", admin)

    assert canceled["monthly_amount"] == %{"amount" => 2000, "currency" => "usd"}
  end

  test "change plan, cancel and resume through Stripe, audited", %{admin: admin, pro: pro} do
    state =
      FakeBilling.stub(Auth, fn
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
      end)

    FakeBilling.put(state, "sub_pro", %{
      "id" => "sub_pro",
      "customer" => "cus_1",
      "status" => "active",
      "cancel_at_period_end" => false,
      "metadata" => %{},
      "items" => %{
        "data" => [
          %{
            "id" => "si_1",
            "quantity" => 2,
            "price" => %{"id" => "price_pro"},
            "current_period_end" => 4_070_908_800
          }
        ]
      }
    })

    path = "payments/subscriptions/#{pro.id}"

    assert {404, _} = post_json(Auth, path <> "/change-plan", admin, %{plan: "gold"})

    assert {200, %{"subscription" => changed}} =
             post_json(Auth, path <> "/change-plan", admin, %{plan: "team"})

    assert changed["plan"] == "team"

    assert {200, %{"subscription" => %{"cancel_at_period_end" => true}}} =
             post_json(Auth, path <> "/cancel", admin)

    assert {200, %{"subscription" => %{"cancel_at_period_end" => false}}} =
             post_json(Auth, path <> "/resume", admin)

    events = dashboard_events(Auth)

    assert [%{metadata: %{"from" => "pro", "to" => "team"}} = changed_event] =
             Enum.filter(events, &(&1.event == "dashboard.subscription.plan_changed"))

    assert changed_event.user_id == pro.reference_id
    assert Enum.any?(events, &(&1.event == "dashboard.subscription.resumed"))

    assert {404, _} = post_json(Auth, "payments/subscriptions/nope/cancel", admin)
  end

  test "changing subscriptions needs its Admin permission", %{ada: ada, pro: pro} do
    assert {403, _} = get_json(Auth, "payments", ada)
    member = Testing.create_user(Auth, email: "member@example.com", role: "user")
    assert {403, _} = post_json(Auth, "payments/subscriptions/#{pro.id}/cancel", member)
  end
end
