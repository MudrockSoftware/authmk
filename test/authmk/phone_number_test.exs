defmodule Authmk.PhoneNumberTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.PhoneNumber,
         send_otp: &__MODULE__.send_sms/2, sign_up_on_verification: true}
      ]

    def send_sms(%{phone_number: number, code: code, purpose: purpose}, _ctx),
      do: send(self(), {:sms, number, purpose, code})
  end

  @moduletag auth: Auth

  @number "+14155550123"

  defp request_code(browser, number \\ @number) do
    {browser, conn} = post(browser, "/phone-number/send-otp", %{phone_number: number})
    assert json(conn) == %{"status" => true}
    assert_received {:sms, ^number, :verification, code}
    {browser, code}
  end

  defp verify(browser, code, extra \\ %{}) do
    post(browser, "/phone-number/verify", Map.merge(%{phone_number: @number, code: code}, extra))
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  describe "signing in with a code" do
    test "an unknown number signs up", %{browser: browser} do
      {browser, code} = request_code(browser)
      {browser, conn} = verify(browser, code)

      user = json(conn)["user"]
      assert user["phone_number"] == @number
      assert user["phone_number_verified"] == true
      assert user["email"] == "14155550123@phone.invalid"
      assert signed_in_user(browser)["phone_number"] == @number
    end

    test "a known number signs in its user", %{browser: browser} do
      {browser, code} = request_code(browser)
      {browser, _conn} = verify(browser, code)
      {browser, _conn} = post(browser, "/sign-out")

      {browser, code} = request_code(browser)
      {browser, _conn} = verify(browser, code)
      assert signed_in_user(browser)["phone_number"] == @number
      assert Repo.aggregate("users", :count) == 1
    end

    test "codes work once", %{browser: browser} do
      {browser, code} = request_code(browser)
      {browser, _conn} = verify(browser, code)
      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn} = verify(browser, code)
      assert json(conn)["error"]["code"] == "invalid_otp"
      assert signed_in_user(browser) == nil
    end

    test "three wrong guesses end a code", %{browser: browser} do
      {browser, code} = request_code(browser)
      wrong = if code == "000000", do: "111111", else: "000000"

      {browser, conn} = verify(browser, wrong)
      assert json(conn)["error"]["code"] == "invalid_otp"
      {browser, _conn} = verify(browser, wrong)
      {browser, conn} = verify(browser, wrong)
      assert json(conn)["error"]["code"] == "too_many_attempts"

      {browser, conn} = verify(browser, code)
      assert json(conn)["error"]["code"] == "invalid_otp"
      assert signed_in_user(browser) == nil
    end

    test "a new code replaces the old one", %{browser: browser} do
      {browser, first} = request_code(browser)
      {browser, second} = request_code(browser)

      if first != second do
        {_browser, conn} = verify(browser, first)
        assert json(conn)["error"]["code"] == "invalid_otp"
      end

      {_browser, conn} = verify(browser, second)
      assert json(conn)["user"]["phone_number"] == @number
    end

    test "with disable_session, only verifies", %{browser: browser} do
      {browser, code} = request_code(browser)
      {browser, conn} = verify(browser, code, %{disable_session: true})
      assert json(conn)["user"]["phone_number_verified"] == true
      assert signed_in_user(browser) == nil
    end

    test "numbers must look like phone numbers", %{browser: browser} do
      for number <- ["4155550123", "+0123456789", "+1 415 555 0123", "call me"] do
        {_browser, conn} = post(browser, "/phone-number/send-otp", %{phone_number: number})
        assert json(conn)["error"]["code"] == "invalid_phone_number"
      end

      refute_received {:sms, _number, _purpose, _code}
    end
  end

  describe "passwords" do
    # Signs up by code, then sets a password with a reset code.
    defp sign_up_with_password(browser) do
      {browser, code} = request_code(browser)
      {browser, _conn} = verify(browser, code)
      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn} =
        post(browser, "/phone-number/request-password-reset", %{phone_number: @number})

      assert json(conn) == %{"status" => true}
      assert_received {:sms, @number, :password_reset, reset_code}

      {browser, conn} =
        post(browser, "/phone-number/reset-password", %{
          phone_number: @number,
          code: reset_code,
          new_password: "correct horse"
        })

      assert json(conn) == %{"status" => true}
      browser
    end

    test "reset by code, then sign in with the number and password", %{browser: browser} do
      browser = sign_up_with_password(browser)

      {browser, conn} =
        post(browser, "/sign-in/phone-number", %{phone_number: @number, password: "correct horse"})

      assert json(conn)["user"]["phone_number"] == @number
      assert signed_in_user(browser)["phone_number"] == @number
    end

    test "wrong passwords and unknown numbers fail the same way", %{browser: browser} do
      browser = sign_up_with_password(browser)

      for {number, password} <- [{@number, "wrong password"}, {"+14155550999", "correct horse"}] do
        {_browser, conn} =
          post(browser, "/sign-in/phone-number", %{phone_number: number, password: password})

        assert conn.status == 401
        assert json(conn)["error"]["code"] == "invalid_credentials"
      end
    end

    test "a reset for an unknown number answers the same, and sends nothing", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/phone-number/request-password-reset", %{phone_number: @number})

      assert json(conn) == %{"status" => true}
      refute_received {:sms, _number, _purpose, _code}
    end

    test "a verification code can't reset a password", %{browser: browser} do
      {browser, code} = request_code(browser)
      {browser, _conn} = verify(browser, code, %{disable_session: true})
      {browser, code} = request_code(browser)

      {_browser, conn} =
        post(browser, "/phone-number/reset-password", %{
          phone_number: @number,
          code: code,
          new_password: "correct horse"
        })

      assert json(conn)["error"]["code"] == "invalid_otp"
    end
  end

  # SMS pumping: changing IPs doesn't get around the limit for one number.
  test "one number gets at most 5 codes an hour, whoever asks", %{browser: browser} do
    for _attempt <- 1..5, do: request_code(Browser.new(Auth))

    {_browser, conn} = post(browser, "/phone-number/send-otp", %{phone_number: @number})
    assert conn.status == 429
    assert json(conn)["error"]["code"] == "rate_limited"
    refute_received {:sms, _number, _purpose, _code}

    # Password resets share the limit, and answer the same whether or not
    # the number is registered.
    {_browser, conn} =
      post(browser, "/phone-number/request-password-reset", %{phone_number: @number})

    assert json(conn)["error"]["code"] == "rate_limited"

    # Other numbers aren't affected.
    {_browser, _code} = request_code(browser, "+14155550124")
  end

  describe "a signed-in user's number" do
    test "is added with a code, and removed", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, code} = request_code(browser)

      {browser, conn} = verify(browser, code, %{update_phone_number: true})
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert json(conn)["user"]["phone_number"] == @number

      {browser, conn} = post(browser, "/phone-number/remove")
      assert json(conn)["user"]["phone_number"] == nil
      assert signed_in_user(browser)["phone_number"] == nil
    end

    test "can't be someone else's", %{browser: browser} do
      {other, code} = request_code(Browser.new(Auth))
      {_other, _conn} = verify(other, code)

      {browser, _user} = sign_up(browser)
      {browser, code} = request_code(browser)
      {_browser, conn} = verify(browser, code, %{update_phone_number: true})
      assert json(conn)["error"]["code"] == "phone_number_taken"
    end

    test "can't be set by the client directly", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {_browser, conn} =
        post(browser, "/update-user", %{phone_number: @number, phone_number_verified: true})

      assert json(conn)["user"]["phone_number"] == nil
    end
  end
end

defmodule Authmk.PhoneNumberOptionsTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.PhoneNumber,
         send_otp: &__MODULE__.send_sms/2, require_verification: true, otp_length: 8}
      ]

    def send_sms(%{phone_number: number, code: code}, _ctx),
      do: send(self(), {:sms, number, code})
  end

  @moduletag auth: Auth

  @number "+14155550123"

  test "without sign-up on verification, unknown numbers are refused", %{browser: browser} do
    {browser, _conn} = post(browser, "/phone-number/send-otp", %{phone_number: @number})
    assert_received {:sms, @number, code}
    assert String.length(code) == 8

    {_browser, conn} = post(browser, "/phone-number/verify", %{phone_number: @number, code: code})
    assert json(conn)["error"]["code"] == "phone_number_not_found"
    assert Repo.aggregate("users", :count) == 0
  end

  test "password sign-in waits for a verified number, and sends a code", %{browser: browser} do
    {browser, user} = sign_up(browser)
    {browser, _conn} = post(browser, "/sign-out")

    # A number the app set itself, not verified yet.
    module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :user)
    Repo.update_all(where(module, id: ^user["id"]), set: [phone_number: @number])

    {browser, conn} =
      post(browser, "/sign-in/phone-number", %{phone_number: @number, password: "correct horse"})

    assert json(conn)["error"]["code"] == "phone_number_not_verified"
    assert_received {:sms, @number, code}

    {browser, _conn} =
      post(browser, "/phone-number/verify", %{
        phone_number: @number,
        code: code,
        disable_session: true
      })

    {_browser, conn} =
      post(browser, "/sign-in/phone-number", %{phone_number: @number, password: "correct horse"})

    assert json(conn)["user"]["phone_number_verified"] == true
  end
end

defmodule Authmk.PhoneNumberStorageTest do
  # Codes in secondary storage instead of the database.
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      secondary_storage: Authmk.Storage.ETS,
      plugins: [
        {Authmk.Plugins.PhoneNumber,
         send_otp: &__MODULE__.send_sms/2, sign_up_on_verification: true}
      ]

    def send_sms(%{phone_number: number, code: code}, _ctx),
      do: send(self(), {:sms, number, code})
  end

  @moduletag auth: Auth

  @number "+14155550123"

  defp request_code(browser) do
    {browser, _conn} = post(browser, "/phone-number/send-otp", %{phone_number: @number})
    assert_received {:sms, @number, code}
    {browser, code}
  end

  test "codes are replaced, used once, and never touch the database", %{browser: browser} do
    {browser, first} = request_code(browser)
    {browser, second} = request_code(browser)
    assert Repo.aggregate("verifications", :count) == 0

    if first != second do
      {_browser, conn} =
        post(browser, "/phone-number/verify", %{phone_number: @number, code: first})

      assert json(conn)["error"]["code"] == "invalid_otp"
    end

    {browser, conn} =
      post(browser, "/phone-number/verify", %{phone_number: @number, code: second})

    assert json(conn)["user"]["phone_number"] == @number

    {_browser, conn} =
      post(browser, "/phone-number/verify", %{phone_number: @number, code: second})

    assert json(conn)["error"]["code"] == "invalid_otp"
  end
end
