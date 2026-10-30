defmodule PlugApp.SecurityTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  test "throwaway email addresses can't sign up" do
    conn =
      post_json("/auth/sign-up/email", %{
        email: "ada@mailinator.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json(conn)["error"]["code"] == "disposable_email"
  end
end
