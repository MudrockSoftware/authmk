defmodule PhoenixAppWeb.HaveIBeenPwnedTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  test "a password from a data breach is refused", %{conn: conn} do
    suffix = :sha |> :crypto.hash("password123") |> Base.encode16() |> String.slice(5..-1//1)
    Req.Test.stub(PhoenixApp.Providers, &Plug.Conn.send_resp(&1, 200, suffix <> ":24230"))

    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-up/email", %{
        email: "ada@example.com",
        password: "password123",
        name: "Ada"
      })

    assert json_response(conn, 422)["error"]["code"] == "password_compromised"
  end
end
