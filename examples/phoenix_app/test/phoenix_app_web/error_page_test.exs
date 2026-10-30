defmodule PhoenixAppWeb.ErrorPageTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing

  test "a failed sign-in lands on the app's own error page, with its branding", %{conn: conn} do
    page = conn |> get("/auth/error", error: "access_denied") |> html_response(400)
    assert page =~ "We couldn't sign you in"
    assert page =~ "Error code: <code>access_denied</code>"

    # The name and colour edited in the dashboard.
    admin = Testing.create_user(PhoenixApp.Auth, email: "admin@example.com", role: "admin")

    build_conn()
    |> put_req_header("origin", "http://localhost:4000")
    |> Testing.sign_in(PhoenixApp.Auth, admin)
    |> post("/admin/auth/api/branding", %{app_name: "Phoenix Shop", primary_color: "#0f766e"})
    |> json_response(200)

    page = build_conn() |> get("/auth/error", error: "access_denied") |> html_response(400)
    assert page =~ "Back to Phoenix Shop"
    assert page =~ "color: #0f766e"
  end

  test "what the error says is escaped", %{conn: conn} do
    page =
      conn
      |> get("/auth/error", error: "x", error_description: "<script>alert(1)</script>")
      |> html_response(400)

    refute page =~ "<script>alert"
    assert page =~ "&lt;script&gt;"
  end
end
