defmodule PhoenixAppWeb.AuthTest do
  use PhoenixAppWeb.ConnCase, async: true

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

  test "the account page sends anonymous visitors home", %{conn: conn} do
    conn = get(conn, ~p"/account")
    assert redirected_to(conn) == "/"
  end

  test "sign out ends the session", %{conn: conn} do
    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)
    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")
    assert json_response(conn, 200) == %{"success" => true}

    conn = conn |> recycle() |> get(~p"/account")
    assert redirected_to(conn) == "/"
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
    conn = conn |> from_browser() |> post("/auth/request-password-reset", %{email: @user.email})
    assert json_response(conn, 200) == %{"status" => true}

    assert_email_sent(fn email ->
      assert email.subject == "Reset your password"
      assert email.text_body =~ "http://localhost:4000/auth/reset-password/"
    end)
  end
end
