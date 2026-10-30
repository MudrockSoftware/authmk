defmodule PhoenixAppWeb.TestingHelpersTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing

  # Authmk.Testing skips the sign-up and sign-in endpoints when a test
  # only needs a signed-in user.
  test "a signed-in user sees the account page", %{conn: conn} do
    user = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com", name: "Ada")

    conn = conn |> Testing.sign_in(PhoenixApp.Auth, user) |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"
  end

  test "users created with a password sign in normally", %{conn: conn} do
    Testing.create_user(PhoenixApp.Auth, email: "ada@example.com", password: "correct horse")

    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"
  end
end
