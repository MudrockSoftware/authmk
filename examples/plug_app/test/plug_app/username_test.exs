defmodule PlugApp.UsernameTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "sign up with a username, then sign in with it" do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada", username: "Ada"}
    conn = post_json("/auth/sign-up/email", user)
    assert json(conn)["user"]["username"] == "ada"

    post_json("/auth/sign-out", %{}, cookies(conn))

    conn = post_json("/auth/sign-in/username", %{username: "ada", password: "correct horse"})
    assert get_path("/me", cookies(conn)).status == 200

    conn = post_json("/auth/is-username-available", %{username: "ada"})
    assert json(conn) == %{"available" => false}
  end
end
