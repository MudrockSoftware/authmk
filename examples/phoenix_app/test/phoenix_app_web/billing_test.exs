defmodule PhoenixAppWeb.BillingTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @webhook_secret "whsec_replace_me"

  # Stripe and Dub, as their APIs answer.
  setup do
    test = self()
    now = System.system_time(:second)

    Req.Test.stub(PhoenixApp.Providers, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:outbound, conn.host, conn.request_path, body})

      case {conn.host, conn.request_path} do
        {"api.dub.co", "/track/lead"} ->
          Req.Test.json(conn, %{"ok" => true})

        {"api.stripe.com", "/v1/customers"} ->
          Req.Test.json(conn, %{"id" => "cus_1"})

        {"api.stripe.com", "/v1/checkout/sessions"} ->
          Req.Test.json(conn, %{"url" => "https://checkout.stripe.com/c/pay/cs_1"})

        {"api.stripe.com", "/v1/subscriptions/sub_1"} ->
          Req.Test.json(conn, %{
            "id" => "sub_1",
            "customer" => "cus_1",
            "status" => "active",
            "cancel_at_period_end" => false,
            "items" => %{
              "data" => [
                %{
                  "quantity" => 1,
                  "price" => %{"id" => "price_pro_monthly"},
                  "current_period_end" => now + 86_400
                }
              ]
            }
          })

        # Have I Been Pwned, at sign-up: nothing breached.
        _other ->
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    :ok
  end

  test "a sign-up from a Dub link subscribes with Stripe", %{conn: conn} do
    signed_up =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> put_req_cookie("dub_id", "click_1")
      |> post("/auth/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse battery",
        name: "Ada"
      })

    user_id = json_response(signed_up, 200)["user"]["id"]
    assert_received {:outbound, "api.dub.co", "/track/lead", lead}
    assert JSON.decode!(lead)["clickId"] == "click_1"

    checkout =
      signed_up
      |> recycle()
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/billing/checkout", %{plan: "pro", success_url: "/account"})

    assert json_response(checkout, 200)["url"] == "https://checkout.stripe.com/c/pay/cs_1"

    # Stripe's webhook, signed: the endpoint keeps bodies as sent (RawBody).
    body =
      JSON.encode!(%{
        "type" => "customer.subscription.created",
        "data" => %{"object" => %{"id" => "sub_1"}}
      })

    t = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, @webhook_secret, "#{t}.#{body}") |> Base.encode16(case: :lower)

    webhook =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=#{t},v1=#{signature}")
      |> post("/auth/billing/webhook", body)

    assert json_response(webhook, 200) == %{"received" => true}

    assert %{plan: "pro", status: "active"} =
             Authmk.Payments.active_subscription(PhoenixApp.Auth, user_id)
  end
end
