defmodule PlugApp.PhoneNumberTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "sign up and in with a code sent by SMS" do
    conn = post_json("/auth/phone-number/send-otp", %{phone_number: "+14155550123"})
    assert json(conn) == %{"status" => true}
    assert_received {:sms, "+14155550123", "Your PlugApp code is " <> code}

    conn = post_json("/auth/phone-number/verify", %{phone_number: "+14155550123", code: code})
    assert json(conn)["user"]["phone_number_verified"] == true
    assert get_path("/me", cookies(conn)).status == 200
  end
end
