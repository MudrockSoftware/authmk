defmodule PlugApp.HaveIBeenPwnedTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a password from a data breach is refused" do
    suffix = :sha |> :crypto.hash("password123") |> Base.encode16() |> String.slice(5..-1//1)
    Req.Test.stub(PlugApp.Providers, &Plug.Conn.send_resp(&1, 200, suffix <> ":24230"))

    conn =
      post_json("/auth/sign-up/email", %{
        email: "ada@example.com",
        password: "password123",
        name: "Ada"
      })

    assert json(conn)["error"]["code"] == "password_compromised"
  end
end
