defmodule PhoenixAppWeb.APIKeyTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "an API key reaches the account page without a cookie", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)
    conn = conn |> recycle() |> from_browser() |> post("/auth/api-key/create", %{name: "script"})
    key = json_response(conn, 200)["key"]

    conn = build_conn() |> put_req_header("x-api-key", key) |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"

    conn = build_conn() |> put_req_header("x-api-key", "wrong") |> get(~p"/account")
    assert redirected_to(conn) == "/"
  end
end
