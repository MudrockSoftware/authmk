defmodule PhoenixAppWeb.BearerTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a mobile client signs in and calls the API with the bearer token", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn |> from_browser() |> post("/auth/sign-up/email", user)

    conn =
      build_conn()
      |> from_browser()
      |> post("/auth/sign-in/email", Map.take(user, [:email, :password]))

    [token] = get_resp_header(conn, "set-auth-token")

    conn =
      build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get("/api/whoami")

    assert json_response(conn, 200) == %{"type" => "user", "name" => "Ada"}
  end
end
