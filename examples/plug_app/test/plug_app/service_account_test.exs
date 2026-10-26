defmodule PlugApp.ServiceAccountTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a service account calls the app with its key" do
    session =
      cookies(
        post_json("/auth/sign-up/email", %{
          email: "ada@example.com",
          password: "correct horse",
          name: "Ada"
        })
      )

    account = json(post_json("/auth/service-account/create", %{name: "Nightly export"}, session))

    key =
      json(post_json("/auth/service-account/create-key", %{id: account["id"]}, session))["key"]

    conn = Plug.Test.conn(:get, "/whoami") |> Plug.Conn.put_req_header("x-api-key", key) |> call()
    assert json(conn) == %{"type" => "service_account", "name" => "Nightly export"}

    # Pages for people stay closed to it.
    conn = Plug.Test.conn(:get, "/me") |> Plug.Conn.put_req_header("x-api-key", key) |> call()
    assert conn.status == 401
  end
end
