defmodule PlugApp.LastSignInMethodTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  test "the sign-in page knows how this browser signed in last" do
    assert json(get_path("/sign-in")) == %{"last_used" => nil}

    browser = cookies(post_json("/auth/sign-up/email", @user))
    post_json("/auth/sign-out", %{}, browser)
    assert json(get_path("/sign-in", browser)) == %{"last_used" => "email"}

    # Kept on the user too, for every device.
    conn = post_json("/auth/sign-in/email", Map.take(@user, [:email, :password]))
    assert json(conn)["user"]["last_sign_in_method"] == "email"
  end
end
