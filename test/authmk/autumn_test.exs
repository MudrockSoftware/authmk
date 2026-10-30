defmodule Authmk.AutumnTest do
  # Autumn keeps plans and balances; authmk attaches plans, opens the
  # portal, asks what's allowed (failing closed) and takes its webhooks.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Autumn
  alias Authmk.Test.{Browser, FakeBilling}

  @webhook_key "autumn webhook key"

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
        {Authmk.Plugins.Autumn,
         api_key: "am_sk_test",
         webhook_secret: "whsec_" <> Base.encode64("autumn webhook key"),
         on_event: &__MODULE__.event/2}
      ]

    def event(event, _ctx), do: send(self(), {:autumn_event, event["type"]})
  end

  @moduletag auth: Auth

  setup do
    FakeBilling.stub(Auth, fn
      "POST", "/v1/customers.get_or_create", _p, _s ->
        {200, %{"id" => "ignored"}}

      "POST", "/v1/billing.attach", %{"plan_id" => "free"}, _s ->
        {200, %{"payment_url" => nil}}

      "POST", "/v1/billing.attach", _p, _s ->
        {200, %{"payment_url" => "https://checkout.stripe.com/autumn/1"}}

      "POST", "/v1/billing.open_customer_portal", _p, _s ->
        {200, %{"url" => "https://billing.stripe.com/autumn/1"}}

      "POST", "/v1/billing.update", _p, _s ->
        {200, %{"customer_id" => "x"}}

      "POST", "/v1/balances.check", %{"feature_id" => "messages"}, _s ->
        {200, %{"allowed" => true}}

      "POST", "/v1/balances.check", %{"feature_id" => "degraded"}, _s ->
        {202, %{"allowed" => true}}

      "POST", "/v1/balances.check", _p, _s ->
        {500, %{}}

      "POST", "/v1/balances.track", _p, _s ->
        {200, %{"balance" => %{"remaining" => 9}}}
    end)

    :ok
  end

  defp webhook(body, key \\ @webhook_key, timestamp \\ System.system_time(:second)) do
    headers =
      for {name, value} <- FakeBilling.standard_headers(body, key, "msg_1", timestamp) do
        {String.replace(name, "webhook-", "svix-"), value}
      end

    FakeBilling.webhook(Auth, body, headers)
  end

  test "attach a plan, open the portal, cancel", %{browser: browser} do
    {browser, user} = sign_up(browser)

    {browser, conn} = post(browser, "/billing/checkout", %{plan: "pro", success_url: "/done"})
    assert json(conn) == %{"url" => "https://checkout.stripe.com/autumn/1", "redirect" => true}

    assert_received {:billing_request, "POST", "/v1/customers.get_or_create", customer, headers}
    assert customer["customer_id"] == user["id"]
    assert {"authorization", "Bearer am_sk_test"} in headers
    assert {"x-api-version", "2.6.0"} in headers
    assert_received {:billing_request, "POST", "/v1/billing.attach", attach, _h}

    assert attach == %{
             "customer_id" => user["id"],
             "plan_id" => "pro",
             "success_url" => "http://localhost:4000/done"
           }

    # Nothing to pay: attached, no redirect.
    {browser, conn} = post(browser, "/billing/checkout", %{plan: "free"})
    assert json(conn) == %{"url" => nil, "redirect" => false}

    {browser, conn} = post(browser, "/billing/portal", %{return_url: "/account"})
    assert json(conn)["url"] == "https://billing.stripe.com/autumn/1"

    {_browser, _conn} = post(browser, "/billing/cancel", %{plan: "pro"})

    assert_received {:billing_request, "POST", "/v1/billing.update",
                     %{"cancel_action" => "cancel_end_of_cycle"}, _h}

    # Signed out: no checkout.
    {_browser, conn} = post(Browser.new(Auth), "/billing/checkout", %{plan: "pro"})
    assert conn.status == 401
  end

  test "what's allowed, failing closed; usage", %{browser: browser} do
    {_browser, user} = sign_up(browser)

    assert {:ok, true} = Autumn.check(Auth, user["id"], "messages")
    # Degraded (Autumn allowed it without checking) or failing: no.
    assert {:ok, false} = Autumn.check(Auth, user["id"], "degraded")
    assert {:ok, false} = Autumn.check(Auth, user["id"], "exports")

    assert :ok = Autumn.track(Auth, user["id"], "messages", 3)

    assert_received {:billing_request, "POST", "/v1/balances.track",
                     %{"value" => 3, "feature_id" => "messages"}, _h}
  end

  test "signed webhooks reach on_event; others don't" do
    body = JSON.encode!(%{"type" => "billing.updated", "data" => %{}})

    assert webhook(body).status == 200
    assert_received {:autumn_event, "billing.updated"}

    assert webhook(body, "another key").status == 400
    assert webhook(body, @webhook_key, System.system_time(:second) - 900).status == 400
    refute_received {:autumn_event, _type}
  end
end
