defmodule PlugApp.APIKeyTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "an API key reaches the protected page without a cookie" do
    session =
      cookies(
        post_json("/auth/sign-up/email", %{
          email: "ada@example.com",
          password: "correct horse",
          name: "Ada"
        })
      )

    key = json(post_json("/auth/api-key/create", %{name: "script"}, session))["key"]

    conn = Plug.Test.conn(:get, "/me") |> Plug.Conn.put_req_header("x-api-key", key) |> call()
    assert json(conn) == %{"email" => "ada@example.com", "name" => "Ada"}

    conn = Plug.Test.conn(:get, "/me") |> Plug.Conn.put_req_header("x-api-key", "wrong") |> call()
    assert conn.status == 401
  end
end
