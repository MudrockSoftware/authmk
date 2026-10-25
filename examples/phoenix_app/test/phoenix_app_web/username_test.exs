defmodule PhoenixAppWeb.UsernameTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "sign up with a username, then sign in with it", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada", username: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)
    assert json_response(conn, 200)["user"]["username"] == "ada"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "@Ada"

    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/sign-in/username", %{username: "ADA", password: "correct horse"})

    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"
  end
end
