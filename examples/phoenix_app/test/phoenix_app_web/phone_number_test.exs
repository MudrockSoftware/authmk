defmodule PhoenixAppWeb.PhoneNumberTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "sign up and in with a code sent by SMS", %{conn: conn} do
    number = "+14155550123"
    conn = conn |> from_browser() |> post("/auth/phone-number/send-otp", %{phone_number: number})
    assert json_response(conn, 200) == %{"status" => true}
    assert_received {:sms, ^number, "Your PhoenixApp code is " <> code}

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/phone-number/verify", %{phone_number: number, code: code})

    assert json_response(conn, 200)["user"]["phone_number"] == number

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ number
  end
end
