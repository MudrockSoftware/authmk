defmodule PlugApp.BearerTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a mobile client signs in and uses the bearer token" do
    post_json("/auth/sign-up/email", %{
      email: "ada@example.com",
      password: "correct horse",
      name: "Ada"
    })

    conn =
      post_json("/auth/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    [token] = Plug.Conn.get_resp_header(conn, "set-auth-token")

    conn =
      Plug.Test.conn(:get, "/me")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> call()

    assert json(conn)["email"] == "ada@example.com"
  end
end
