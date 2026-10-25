defmodule PlugApp.TwoFactorTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  import Swoosh.TestAssertions

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  defp secret(totp_uri) do
    %{"secret" => secret} = totp_uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    Base.decode32!(secret, padding: false)
  end

  test "turn 2FA on, then sign in with a code sent by email" do
    session = cookies(post_json("/auth/sign-up/email", @user))

    conn = post_json("/auth/two-factor/enable", %{password: @user.password}, session)
    %{"totp_uri" => uri, "backup_codes" => [_ | _]} = json(conn)

    code = NimbleTOTP.verification_code(secret(uri))
    conn = post_json("/auth/two-factor/verify-totp", %{code: code}, session)
    assert json(conn)["user"]["two_factor_enabled"] == true

    post_json("/auth/sign-out", %{}, session)

    # The password alone doesn't sign in.
    conn = post_json("/auth/sign-in/email", Map.take(@user, [:email, :password]))
    assert json(conn)["two_factor_redirect"] == true
    challenge = cookies(conn)
    assert get_path("/me", challenge).status == 401

    conn = post_json("/auth/two-factor/send-otp", %{}, challenge)
    challenge = Map.merge(challenge, cookies(conn))

    assert_email_sent(fn email ->
      assert email.subject == "Your sign-in code"
      [_, otp] = Regex.run(~r/(\d{6})/, email.text_body)
      send(self(), {:otp, otp})
    end)

    assert_received {:otp, otp}
    conn = post_json("/auth/two-factor/verify-otp", %{code: otp}, challenge)
    assert get_path("/me", cookies(conn)).status == 200
  end
end
