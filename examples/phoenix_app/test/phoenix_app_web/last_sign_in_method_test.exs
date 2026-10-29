defmodule PhoenixAppWeb.LastSignInMethodTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "the home page points at the method used last", %{conn: conn} do
    refute html_response(get(conn, ~p"/"), 200) =~ "Last time"

    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)
    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Last time you signed in with email."
  end
end
