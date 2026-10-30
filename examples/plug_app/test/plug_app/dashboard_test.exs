defmodule PlugApp.DashboardTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing

  defp as(user, method, path, body \\ nil) do
    conn(method, "/admin/auth/api/" <> path, body && JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "http://localhost:4001")
    |> Testing.sign_in(PlugApp.Auth, user)
    |> call()
  end

  setup do
    %{admin: Testing.create_user(PlugApp.Auth, email: "admin@example.com", role: "admin")}
  end

  test "admins get the dashboard and its API", %{admin: admin} do
    page = conn(:get, "/admin/auth/") |> Testing.sign_in(PlugApp.Auth, admin) |> call()
    assert page.status == 200
    assert page.resp_body =~ "./_app/"

    assert json(as(admin, :get, "overview"))["totals"]["users"] == 1
  end

  test "everyone else is sent away" do
    user = Testing.create_user(PlugApp.Auth, email: "ada@example.com")
    page = conn(:get, "/admin/auth/") |> Testing.sign_in(PlugApp.Auth, user) |> call()
    assert get_resp_header(page, "location") == ["/"]
    assert get_path("/admin/auth/api/me").status == 401
  end

  test "managing a user: their company, a ban, and the audit log", %{admin: admin} do
    ada = Testing.create_user(PlugApp.Auth, email: "ada@example.com")

    detail = json(as(admin, :get, "users/#{ada.id}"))
    assert [%{"name" => "company", "editable" => true}] = detail["fields"]

    assert as(admin, :post, "users/#{ada.id}/update", %{fields: %{company: "Acme"}}).status ==
             200

    assert as(admin, :post, "users/#{ada.id}/ban", %{reason: "Spam"}).status == 200
    assert Testing.get_user_by(PlugApp.Auth, email: "ada@example.com").company == "Acme"
    assert Testing.get_user_by(PlugApp.Auth, email: "ada@example.com").banned

    events = json(as(admin, :get, "events?event=dashboard.user.banned"))["events"]
    assert [%{"user_id" => user_id}] = events
    assert user_id == to_string(ada.id)
  end

  test "analytics, exports and health", %{admin: admin} do
    report = json(as(admin, :get, "analytics"))
    assert report["source"] == "audit_log"
    assert report["adoption"]["users"] == 1

    export = as(admin, :get, "exports/users.csv")
    assert export.resp_body =~ "admin@example.com"

    checks = json(as(admin, :get, "health"))["checks"]
    assert %{"status" => "ok"} = Enum.find(checks, &(&1["name"] == "Audit log"))
  end

  test "earnings from the plans' prices", %{admin: admin} do
    {:ok, _subscription} =
      Authmk.Store.insert(Authmk.Context.new(PlugApp.Auth.config()), :subscription, %{
        provider: "stripe",
        reference_id: to_string(admin.id),
        reference_type: "user",
        provider_subscription_id: "sub_1",
        price_id: "price_pro_yearly",
        plan: "pro",
        status: "active"
      })

    earnings = json(as(admin, :get, "payments"))["earnings"]
    # 200 USD a year is 16.67 a month.
    assert [%{"currency" => "usd", "monthly" => 1667}] = earnings["recurring_revenue"]
  end

  test "branding edited here shows on authmk's error page", %{admin: admin} do
    assert as(admin, :post, "branding", %{app_name: "Plug Shop", primary_color: "#0f766e"}).status ==
             200

    page = get_path("/auth/error?error=access_denied")
    assert page.resp_body =~ ~s("app_name":"Plug Shop")
    assert page.resp_body =~ ~s("primary_color":"#0f766e")
  end
end
