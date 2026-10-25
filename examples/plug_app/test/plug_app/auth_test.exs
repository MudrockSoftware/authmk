defmodule PlugApp.AuthTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  import Swoosh.TestAssertions

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  test "sign up, then reach a protected page with the session cookie" do
    conn = post_json("/auth/sign-up/email", @user)
    assert conn.status == 200

    conn = get_path("/me", cookies(conn))
    assert json(conn) == %{"email" => "ada@example.com", "name" => "Ada"}
  end

  test "the protected page rejects anonymous visitors" do
    conn = get_path("/me")
    assert conn.status == 401
  end

  test "sign in after signing out" do
    session = cookies(post_json("/auth/sign-up/email", @user))
    post_json("/auth/sign-out", %{}, session)
    assert get_path("/me", session).status == 401

    conn = post_json("/auth/sign-in/email", Map.take(@user, [:email, :password]))
    assert get_path("/me", cookies(conn)).status == 200
  end

  test "password reset email goes through the app's mailer" do
    post_json("/auth/sign-up/email", @user)
    conn = post_json("/auth/request-password-reset", %{email: "ada@example.com"})
    assert json(conn) == %{"status" => true}

    assert_email_sent(fn email ->
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Reset your password"
      assert email.text_body =~ "http://localhost:4001/auth/reset-password/"
    end)
  end
end
