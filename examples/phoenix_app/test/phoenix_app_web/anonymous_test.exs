defmodule PhoenixAppWeb.AnonymousTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a guest signs up later and becomes a real user", %{conn: conn} do
    conn = conn |> from_browser() |> post("/auth/sign-in/anonymous")
    assert json_response(conn, 200)["user"]["is_anonymous"] == true

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as a guest"

    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-up/email", user)
    assert json_response(conn, 200)["user"]["is_anonymous"] == false

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as ada@example.com"
  end
end
