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

    # Without the captcha, no reset.
    conn = post_json("/auth/request-password-reset", %{email: "ada@example.com"})
    assert json(conn)["error"]["code"] == "captcha_required"

    # Turnstile, played by the providers' stub.
    Req.Test.stub(PlugApp.Providers, &Req.Test.json(&1, %{"success" => true}))

    conn =
      Plug.Test.conn(
        :post,
        "/auth/request-password-reset",
        JSON.encode!(%{email: "ada@example.com"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "http://localhost:4001")
      |> Plug.Conn.put_req_header("x-captcha-response", "token-from-the-widget")
      |> call()

    assert json(conn) == %{"status" => true}

    assert_email_sent(fn email ->
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Reset your password"
      assert email.text_body =~ "http://localhost:4001/auth/reset-password/"
      send(self(), {:reset_link, Regex.run(~r{/auth/reset-password/\S+}, email.text_body)})
    end)

    # No redirect_to: the link opens the app's reset_password_page.
    assert_received {:reset_link, [link]}
    conn = get_path(link)
    assert "/reset-password?token=" <> token = Plug.Conn.get_resp_header(conn, "location") |> hd()
    assert get_path("/reset-password?token=" <> token).resp_body =~ ~s(name="new_password")

    # Have I Been Pwned, played by the stub: the new password isn't in a breach.
    Req.Test.stub(PlugApp.Providers, &Plug.Conn.send_resp(&1, 200, ""))
    conn = post_json("/auth/reset-password", %{token: token, new_password: "new password 1"})
    assert json(conn) == %{"status" => true}

    conn =
      post_json("/auth/sign-in/email", %{email: "ada@example.com", password: "new password 1"})

    assert conn.status == 200
  end
end
