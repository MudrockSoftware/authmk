defmodule PhoenixAppWeb.AuthTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  # Browsers send Origin on POSTs; authmk checks it against base_url.
  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "sign up through /auth, then see the signed-in pages", %{conn: conn} do
    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)
    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as ada@example.com"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"
  end

  test "the account page sends anonymous visitors to sign in", %{conn: conn} do
    conn = get(conn, ~p"/account")
    assert redirected_to(conn) == "/sign-in"
  end

  test "sign out ends the session", %{conn: conn} do
    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)
    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")
    assert json_response(conn, 200) == %{"success" => true}

    conn = conn |> recycle() |> get(~p"/account")
    assert redirected_to(conn) == "/sign-in"
  end

  test "requests from other sites are rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> post("/auth/sign-up/email", @user)

    assert json_response(conn, 403)["error"]["code"] == "invalid_origin"
  end

  test "password reset email goes through the app's Swoosh mailer", %{conn: conn} do
    conn |> from_browser() |> post("/auth/sign-up/email", @user)

    # Without the captcha, no reset.
    denied =
      build_conn()
      |> from_browser()
      |> post("/auth/request-password-reset", %{email: @user.email})

    assert json_response(denied, 400)["error"]["code"] == "captcha_required"

    # Turnstile, played by the providers' stub.
    Req.Test.stub(PhoenixApp.Providers, &Req.Test.json(&1, %{"success" => true}))

    conn =
      conn
      |> from_browser()
      |> put_req_header("x-captcha-response", "token-from-the-widget")
      |> post("/auth/request-password-reset", %{email: @user.email})

    assert json_response(conn, 200) == %{"status" => true}

    assert_email_sent(fn email ->
      assert email.subject == "Reset your password"
      assert email.text_body =~ "http://localhost:4000/auth/reset-password/"
      send(self(), {:reset_link, Regex.run(~r{/auth/reset-password/\S+}, email.text_body)})
    end)

    # No redirect_to: the link opens the reset_password_page, a LiveView.
    assert_received {:reset_link, [link]}
    "/reset-password?token=" <> _token = path = build_conn() |> get(link) |> redirected_to()
    {:ok, _view, html} = live(build_conn(), path)
    assert html =~ "new_password"
  end
end
