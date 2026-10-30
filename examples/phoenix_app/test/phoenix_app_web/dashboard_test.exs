defmodule PhoenixAppWeb.DashboardTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing

  test "admins get the dashboard and its API", %{conn: conn} do
    admin = Testing.create_user(PhoenixApp.Auth, email: "admin@example.com", role: "admin")
    Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")
    signed_in = Testing.sign_in(conn, PhoenixApp.Auth, admin)

    assert signed_in |> get("/admin/auth/") |> html_response(200) =~ "./_app/"

    users =
      signed_in |> recycle() |> get("/admin/auth/api/users", search: "ada") |> json_response(200)

    assert [%{"email" => "ada@example.com"}] = users["users"]
  end

  test "everyone else is sent away", %{conn: conn} do
    user = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")

    assert conn
           |> Testing.sign_in(PhoenixApp.Auth, user)
           |> get("/admin/auth/")
           |> redirected_to() == "/"

    assert build_conn() |> get("/admin/auth/api/me") |> json_response(401)
  end
end
