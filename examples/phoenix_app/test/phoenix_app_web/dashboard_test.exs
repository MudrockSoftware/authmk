defmodule PhoenixAppWeb.DashboardTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing

  setup do
    %{admin: Testing.create_user(PhoenixApp.Auth, email: "admin@example.com", role: "admin")}
  end

  defp as(user) do
    build_conn()
    |> put_req_header("origin", "http://localhost:4000")
    |> Testing.sign_in(PhoenixApp.Auth, user)
  end

  test "admins get the dashboard and its API", %{admin: admin} do
    Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")
    assert admin |> as() |> get("/admin/auth/") |> html_response(200) =~ "./_app/"

    users = admin |> as() |> get("/admin/auth/api/users", search: "ada") |> json_response(200)
    assert [%{"email" => "ada@example.com"}] = users["users"]
  end

  test "everyone else is sent away" do
    user = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")
    assert user |> as() |> get("/admin/auth/") |> redirected_to() == "/"
    assert build_conn() |> get("/admin/auth/api/me") |> json_response(401)
  end

  test "an organization run from the dashboard", %{admin: admin} do
    Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")

    %{"id" => id} =
      admin
      |> as()
      |> post("/admin/auth/api/organizations", %{
        name: "Acme",
        slug: "acme",
        owner_email: "ada@example.com"
      })
      |> json_response(200)

    admin
    |> as()
    |> post("/admin/auth/api/organizations/#{id}/invitations", %{
      email: "grace@example.com",
      role: "member"
    })
    |> json_response(200)

    detail = admin |> as() |> get("/admin/auth/api/organizations/#{id}") |> json_response(200)
    assert [%{"role" => "owner"}] = detail["members"]
    assert [%{"email" => "grace@example.com", "status" => "pending"}] = detail["invitations"]

    # What Ada can do there, and why.
    [%{"user" => %{"id" => ada_id}}] = detail["members"]
    access = admin |> as() |> get("/admin/auth/api/users/#{ada_id}") |> json_response(200)

    assert [%{"name" => "Acme", "roles" => [%{"name" => "owner"}]}] =
             access["access"]["organizations"]
  end

  test "analytics, earnings and health", %{admin: admin} do
    report = admin |> as() |> get("/admin/auth/api/analytics") |> json_response(200)
    assert length(report["sign_ups"]) == 30

    payments = admin |> as() |> get("/admin/auth/api/payments") |> json_response(200)
    assert payments["provider"] == "stripe"
    assert payments["supports"]["change_plan"]

    checks = admin |> as() |> get("/admin/auth/api/health") |> json_response(200)
    assert Enum.any?(checks["checks"], &(&1["area"] == "Audit log"))
  end
end
