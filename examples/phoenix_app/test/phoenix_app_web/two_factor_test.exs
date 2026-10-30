defmodule PhoenixAppWeb.TwoFactorTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  defp secret(totp_uri) do
    %{"secret" => secret} = totp_uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    Base.decode32!(secret, padding: false)
  end

  test "turn 2FA on, then sign in with a code sent by email", %{conn: conn} do
    conn = conn |> from_browser() |> post("/auth/sign-up/email", @user)

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/two-factor/enable", %{password: @user.password})

    code = NimbleTOTP.verification_code(secret(json_response(conn, 200)["totp_uri"]))

    conn =
      conn |> recycle() |> from_browser() |> post("/auth/two-factor/verify-totp", %{code: code})

    assert json_response(conn, 200)["status"] == true

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "On"

    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")

    # The password alone doesn't sign in.
    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/sign-in/email", Map.take(@user, [:email, :password]))

    assert json_response(conn, 200)["two_factor_redirect"] == true
    assert conn |> recycle() |> get(~p"/account") |> redirected_to() == "/sign-in"

    conn = conn |> recycle() |> from_browser() |> post("/auth/two-factor/send-otp")
    assert json_response(conn, 200)["status"] == true

    assert_email_sent(fn email ->
      [_, otp] = Regex.run(~r/(\d{6})/, email.text_body)
      send(self(), {:otp, otp})
    end)

    assert_received {:otp, otp}

    conn =
      conn |> recycle() |> from_browser() |> post("/auth/two-factor/verify-otp", %{code: otp})

    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"
  end
end
