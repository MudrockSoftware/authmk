defmodule PlugApp.TestingHelpersTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing

  # Authmk.Testing skips the sign-up and sign-in endpoints when a test
  # only needs a signed-in user.
  test "a signed-in user reaches the protected page" do
    user = Testing.create_user(PlugApp.Auth, email: "ada@example.com", name: "Ada")

    conn =
      conn(:get, "/me")
      |> Testing.sign_in(PlugApp.Auth, user)
      |> call()

    assert json(conn) == %{"email" => "ada@example.com", "name" => "Ada"}
  end

  test "users created with a password sign in normally" do
    Testing.create_user(PlugApp.Auth, email: "ada@example.com", password: "correct horse")

    conn =
      post_json("/auth/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert conn.status == 200
  end
end
