defmodule PhoenixAppWeb.OneTimeTokenTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a signed-in user hands their sign-in to another device", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)

    token =
      conn
      |> recycle()
      |> get("/auth/one-time-token/generate")
      |> json_response(200)
      |> Map.fetch!("token")

    other = build_conn() |> from_browser() |> post("/auth/one-time-token/verify", %{token: token})
    assert other |> recycle() |> get(~p"/account") |> html_response(200) =~ "Ada"
  end
end
