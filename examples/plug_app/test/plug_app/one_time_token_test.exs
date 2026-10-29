defmodule PlugApp.OneTimeTokenTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a signed-in user hands their sign-in to another device" do
    session =
      cookies(
        post_json("/auth/sign-up/email", %{
          email: "ada@example.com",
          password: "correct horse",
          name: "Ada"
        })
      )

    token = json(get_path("/auth/one-time-token/generate", session))["token"]

    other_device = cookies(post_json("/auth/one-time-token/verify", %{token: token}))
    assert json(get_path("/me", other_device))["email"] == "ada@example.com"
  end
end
