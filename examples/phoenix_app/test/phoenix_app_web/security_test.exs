defmodule PhoenixAppWeb.SecurityTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  test "throwaway email addresses can't sign up", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-up/email", %{
        email: "ada@mailinator.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json_response(conn, 400)["error"]["code"] == "disposable_email"
  end
end
