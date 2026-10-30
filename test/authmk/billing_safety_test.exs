defmodule Authmk.BillingSafetyTest do
  # What keeps people from paying twice, or getting what someone else paid
  # for: with integer ids, user 1 and organization 1 are billed apart; one
  # subscription at a time; webhooks that couldn't be saved come again.
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
      primary_key: :id,
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.Stripe,
         api_key: "sk_test_123",
         webhook_secret: "whsec_test_secret",
         organizations: true,
         plans: [
           [name: "pro", id: "price_pro", limits: %{projects: 20}],
           [name: "team", id: "price_team", limits: %{projects: true}]
         ],
         on_subscription_created: &__MODULE__.created/2}
      ]

    def created(subscription, _ctx), do: send(self(), {:created, subscription.reference_type})
  end

  # The app decides who manages an organization's billing.
  defmodule Delegated do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, Authmk.BillingSafetyTest.Auth}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.Stripe,
         api_key: "sk_test_123",
         webhook_secret: "whsec_test_secret",
         organizations: true,
         authorize_reference: &__MODULE__.authorize/4,
         plans: [[name: "pro", id: "price_pro"]]}
      ]

    def authorize(user, _organization_id, action, _ctx),
      do: user.email == "finance@example.com" and action in [:checkout, :list]
  end

  # Organizations not turned on: only users are billed.
  defmodule UsersOnly do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, Authmk.BillingSafetyTest.Auth}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.Stripe,
         api_key: "sk_test_123",
         webhook_secret: "whsec_test_secret",
         plans: [[name: "pro", id: "price_pro"]]}
      ]
  end

  @moduletag auth: Auth

  setup do
    state =
      FakeBilling.stub(Auth, fn
        "POST", "/v1/customers", _params, _state ->
          {200, %{"id" => "cus_#{System.unique_integer([:positive])}"}}

        "POST", "/v1/checkout/sessions", _params, _state ->
          {200, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/pay/cs_1"}}

        "GET", "/v1/subscriptions/" <> id, _params, state ->
          {200, FakeBilling.get(state, id)}
      end)

    %{stripe: state}
  end

  defp subscription(id, customer, status, price) do
    %{
      "id" => id,
      "object" => "subscription",
      "customer" => customer,
      "status" => status,
      "cancel_at_period_end" => false,
      "metadata" => %{},
      "items" => %{
        "data" => [
          %{
            "id" => "si_1",
            "quantity" => 1,
            "price" => %{"id" => price},
            "current_period_end" => System.system_time(:second) + 30 * 86_400
          }
        ]
      }
    }
  end

  defp send_event(subscription_id) do
    body =
      JSON.encode!(%{
        "id" => "evt_1",
        "type" => "customer.subscription.updated",
        "data" => %{"object" => %{"id" => subscription_id, "object" => "subscription"}}
      })

    FakeBilling.webhook(Auth, body, [
      {"stripe-signature", FakeBilling.stripe_signature(body, @secret)}
    ])
  end

  defp customer_of(type, id) do
    Repo.one!(
      from c in "billing_customers",
        where: c.reference_type == ^type and c.reference_id == ^to_string(id),
        select: c.customer_id
    )
  end

  defp checkout(browser, params) do
    post(browser, "/billing/checkout", Map.merge(%{plan: "pro", success_url: "/"}, params))
  end

  test "user 1 and organization 1 are billed apart", %{browser: browser, stripe: stripe} do
    {owner, owner_user} = sign_up(browser)

    {:ok, organization} =
      Authmk.Store.insert(Authmk.Context.new(Auth.config()), :organization, %{
        name: "Acme",
        slug: "acme"
      })

    # The same id: the case this guards against.
    assert to_string(organization.id) == to_string(owner_user["id"])
    {:ok, _} = Organization.add_member(Auth, organization.id, owner_user["id"], "owner")
    org_id = to_string(organization.id)

    {owner, conn} = checkout(owner, %{plan: "team", reference_id: org_id})
    assert json(conn)["redirect"]

    FakeBilling.put(
      stripe,
      "sub_org",
      subscription("sub_org", customer_of("organization", org_id), "active", "price_team")
    )

    assert send_event("sub_org").status == 200
    assert_received {:created, "organization"}

    assert Payments.allowed?(Auth, {:organization, org_id}, :projects, 1000)
    refute Payments.allowed?(Auth, owner_user["id"], :projects, 1)
    {owner, conn} = get(owner, "/billing/subscriptions")
    assert json(conn) == []

    # The owner's own checkout: their own customer, not blocked by the
    # organization's subscription.
    {_owner, conn} = checkout(owner, %{})
    assert json(conn)["redirect"]
    assert customer_of("user", owner_user["id"]) != customer_of("organization", org_id)
  end

  test "one subscription at a time, including while a payment is owed", %{
    browser: browser,
    stripe: stripe
  } do
    {browser, user} = sign_up(browser)
    {browser, conn} = checkout(browser, %{})
    assert json(conn)["redirect"]
    customer = customer_of("user", user["id"])

    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, "active", "price_pro"))
    assert send_event("sub_1").status == 200

    # Another plan on top: no, change plans in the portal.
    {browser, conn} = checkout(browser, %{plan: "team"})
    assert conn.status == 409
    assert json(conn)["error"]["code"] == "already_subscribed"

    # A failed renewal: no access, and still no second subscription.
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, "past_due", "price_pro"))
    assert send_event("sub_1").status == 200
    refute Payments.allowed?(Auth, user["id"], :projects, 1)
    {browser, conn} = checkout(browser, %{})
    assert json(conn)["error"]["code"] == "already_subscribed"

    # Ended: subscribing again is fine.
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, "canceled", "price_pro"))
    assert send_event("sub_1").status == 200
    {_browser, conn} = checkout(browser, %{})
    assert json(conn)["redirect"]
  end

  test "seats outside 1 to 10000 are refused", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    for seats <- [0, -1, 10_001] do
      {_browser, conn} = checkout(browser, %{seats: seats})
      assert json(conn)["error"]["code"] == "invalid_seats"
    end

    refute_received {:billing_request, "POST", "/v1/checkout/sessions", _form, _headers}
  end

  test "a webhook that can't be saved fails, so the provider sends it again", %{
    browser: browser,
    stripe: stripe
  } do
    {browser, user} = sign_up(browser)
    {_browser, _conn} = checkout(browser, %{})
    customer = customer_of("user", user["id"])

    # A status the table can't take (nil): not saved, 500, nothing stored.
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, nil, "price_pro"))
    assert send_event("sub_1").status == 500
    assert Payments.subscriptions(Auth, user["id"]) == []

    # Sent again once it's readable: saved.
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, "active", "price_pro"))
    assert send_event("sub_1").status == 200
    assert [%{status: "active"}] = Payments.subscriptions(Auth, user["id"])
  end

  defp organization(auth) do
    {:ok, organization} =
      Authmk.Store.insert(Authmk.Context.new(auth.config()), :organization, %{
        name: "Acme",
        slug: "acme-#{System.unique_integer([:positive])}"
      })

    to_string(organization.id)
  end

  test "nobody bills what isn't theirs", %{browser: browser, stripe: stripe} do
    {owner, owner_user} = sign_up(browser)
    {other, other_user} = sign_up(browser, %{email: "grace@example.com"})
    org_id = organization(Auth)
    {:ok, _} = Organization.add_member(Auth, org_id, owner_user["id"], "owner")

    # No such organization, an id that isn't one, not a manager: forbidden.
    for reference_id <- ["999", "not-an-id"] do
      {_owner, conn} = checkout(owner, %{reference_id: reference_id})
      assert json(conn)["error"]["code"] == "forbidden"
    end

    {other, conn} = get(other, "/billing/subscriptions", %{reference_id: org_id})
    assert json(conn)["error"]["code"] == "forbidden"

    {_owner, conn} = checkout(owner, %{plan: "platinum"})
    assert json(conn)["error"]["code"] == "plan_not_found"

    # No customer yet: no portal.
    {other, conn} = post(other, "/billing/portal", %{return_url: "/"})
    assert json(conn)["error"]["code"] == "no_billing_customer"

    # Someone else's subscription, by its id: not found.
    {owner, _conn} = checkout(owner, %{})
    customer = customer_of("user", owner_user["id"])
    FakeBilling.put(stripe, "sub_1", subscription("sub_1", customer, "active", "price_pro"))
    assert send_event("sub_1").status == 200
    {_owner, conn} = get(owner, "/billing/subscriptions")
    [%{"id" => id}] = json(conn)

    for subscription_id <- [to_string(id), "not-an-id"] do
      {_other, conn} = post(other, "/billing/cancel", %{subscription_id: subscription_id})
      assert json(conn)["error"]["code"] == "subscription_not_found"
    end

    assert Payments.allowed?(Auth, owner_user["id"], :projects, 20)
    refute Payments.allowed?(Auth, other_user["id"], :projects, 1)
  end

  @tag auth: Delegated
  test "authorize_reference decides who manages an organization's billing", %{browser: browser} do
    {owner, owner_user} = sign_up(browser)
    {finance, _user} = sign_up(browser, %{email: "finance@example.com"})
    org_id = organization(Delegated)
    {:ok, _} = Organization.add_member(Delegated, org_id, owner_user["id"], "owner")

    # The owner, a manager by role, isn't allowed by the app; finance is.
    {_owner, conn} = checkout(owner, %{reference_id: org_id})
    assert json(conn)["error"]["code"] == "forbidden"

    {finance, conn} = checkout(finance, %{reference_id: org_id})
    assert json(conn)["redirect"]
    {finance, conn} = get(finance, "/billing/subscriptions", %{reference_id: org_id})
    assert json(conn) == []

    # Only for what it allowed.
    {_finance, conn} = post(finance, "/billing/portal", %{reference_id: org_id, return_url: "/"})
    assert json(conn)["error"]["code"] == "forbidden"
  end

  @tag auth: UsersOnly
  test "without organizations: true, only the user is billed", %{browser: browser} do
    {user_browser, user} = sign_up(browser)
    org_id = organization(UsersOnly)
    {:ok, _} = Organization.add_member(UsersOnly, org_id, user["id"], "owner")

    {_browser, conn} = checkout(user_browser, %{reference_id: org_id})
    assert json(conn)["error"]["code"] == "forbidden"
  end

  test "the provider unreachable: a generic error", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    Req.Test.stub(Auth, &Req.Test.transport_error(&1, :econnrefused))

    {_browser, conn} = checkout(browser, %{})
    assert conn.status == 502
    assert json(conn)["error"]["code"] == "payment_provider_unavailable"
  end

  test "a webhook whose raw body wasn't kept is refused, and says why" do
    # The app's Plug.Parsers parsed it without Authmk.Plug.RawBody.
    conn =
      Plug.Test.conn(:post, "/auth/billing/webhook", %{"type" => "customer.subscription.updated"})
      |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=00")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = Plug.forward(conn, ["billing", "webhook"], Auth, Auth.init([]))
        assert conn.status == 500
      end)

    assert log =~ "Authmk.Plug.RawBody"
  end

  test "a subscription read back without its customer is ignored, not a crash", %{
    browser: browser,
    stripe: stripe
  } do
    {_browser, user} = sign_up(browser)

    FakeBilling.put(
      stripe,
      "sub_1",
      Map.delete(subscription("sub_1", nil, "active", "price_pro"), "customer")
    )

    assert send_event("sub_1").status == 200
    assert Payments.subscriptions(Auth, user["id"]) == []
  end
end
