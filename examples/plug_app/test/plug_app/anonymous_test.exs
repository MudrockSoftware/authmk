defmodule PlugApp.AnonymousTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a guest signs up later and becomes a real user" do
    conn = post_json("/auth/sign-in/anonymous", %{})
    assert json(conn)["user"]["is_anonymous"] == true
    guest = cookies(conn)
    assert get_path("/me", guest).status == 200

    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = post_json("/auth/sign-up/email", user, guest)

    assert json(get_path("/me", cookies(conn))) == %{
             "email" => "ada@example.com",
             "name" => "Ada"
           }

    # The guest is gone.
    assert get_path("/me", guest).status == 401
  end
end
