defmodule PhoenixAppWeb.PasswordlessTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "sign in with a link sent by email", %{conn: conn} do
    conn =
      conn
      |> from_browser()
      |> post("/auth/sign-in/magic-link", %{email: "ada@example.com", callback_url: "/account"})

    assert json_response(conn, 200) == %{"status" => true}

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://\S+}, email.text_body)
      send(self(), {:link, url})
    end)

    assert_received {:link, url}
    conn = conn |> recycle() |> get(url)
    assert redirected_to(conn) == "/account"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "ada@example.com"
  end

  test "sign in with a code sent by email", %{conn: conn} do
    conn =
      conn
      |> from_browser()
      |> post("/auth/email-otp/send-verification-otp", %{email: "ada@example.com", type: "sign-in"})

    assert_email_sent(fn email ->
      [_, code] = Regex.run(~r/(\d{6})/, email.text_body)
      send(self(), {:code, code})
    end)

    assert_received {:code, code}

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/sign-in/email-otp", %{email: "ada@example.com", otp: code})

    assert json_response(conn, 200)["user"]["email_verified"] == true
  end
end
