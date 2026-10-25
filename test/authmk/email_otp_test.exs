defmodule Authmk.EmailOTPTest do
  use Authmk.EmulationCase, async: true

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
        {Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_otp/2}
      ]

    def send_otp(%{email: email, otp: otp, type: type}, _ctx),
      do: send(self(), {:otp, email, type, otp})
  end

  @moduletag auth: Auth

  defp request(browser, email, type) do
    {browser, conn} =
      post(browser, "/email-otp/send-verification-otp", %{email: email, type: type})

    assert json(conn) == %{"success" => true}
    browser
  end

  defp received_code(email, type) do
    assert_received {:otp, ^email, ^type, otp}
    otp
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  describe "signing in with a code" do
    test "a new email signs up, verified", %{browser: browser} do
      browser = request(browser, "Ada@Example.com", "sign-in")
      otp = received_code("ada@example.com", :sign_in)

      {browser, conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp, name: "Ada"})

      assert json(conn)["user"]["name"] == "Ada"
      assert json(conn)["user"]["email_verified"] == true
      assert signed_in_user(browser)["email"] == "ada@example.com"
    end

    test "an existing user signs in, and their email is verified now", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn} = post(browser, "/sign-out")

      browser = request(browser, "ada@example.com", "sign-in")
      otp = received_code("ada@example.com", :sign_in)

      {browser, _conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp})

      assert signed_in_user(browser)["email_verified"] == true
      assert Repo.aggregate("users", :count) == 1
    end

    test "codes work once, for their own type", %{browser: browser} do
      browser = request(browser, "ada@example.com", "sign-in")
      otp = received_code("ada@example.com", :sign_in)

      # Not a reset code.
      {browser, conn} =
        post(browser, "/email-otp/reset-password", %{
          email: "ada@example.com",
          otp: otp,
          password: "new password"
        })

      assert json(conn)["error"]["code"] == "invalid_otp"

      {browser, _conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp})

      {browser, _conn} = post(browser, "/sign-out")

      {_browser, conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp})

      assert json(conn)["error"]["code"] == "invalid_otp"
    end

    test "wrong guesses run out", %{browser: browser} do
      browser = request(browser, "ada@example.com", "sign-in")
      otp = received_code("ada@example.com", :sign_in)
      wrong = if otp == "000000", do: "111111", else: "000000"

      {browser, _conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: wrong})

      {browser, _conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: wrong})

      {browser, conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: wrong})

      assert json(conn)["error"]["code"] == "too_many_attempts"

      {_browser, conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp})

      assert json(conn)["error"]["code"] == "invalid_otp"
    end

    test "checking a code doesn't use it up", %{browser: browser} do
      browser = request(browser, "ada@example.com", "sign-in")
      otp = received_code("ada@example.com", :sign_in)

      {browser, conn} =
        post(browser, "/email-otp/check-verification-otp", %{
          email: "ada@example.com",
          type: "sign-in",
          otp: otp
        })

      assert json(conn) == %{"success" => true}

      {_browser, conn} =
        post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: otp})

      assert json(conn)["user"]["email"] == "ada@example.com"
    end

    test "unknown types are refused", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/email-otp/send-verification-otp", %{
          email: "ada@example.com",
          type: "admin"
        })

      assert json(conn)["error"]["code"] == "invalid_otp_type"
    end
  end

  describe "email verification" do
    test "verifies the email of a password user", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      browser = request(browser, "ada@example.com", "email-verification")
      otp = received_code("ada@example.com", :email_verification)

      {browser, conn} =
        post(browser, "/email-otp/verify-email", %{email: "ada@example.com", otp: otp})

      assert json(conn)["user"]["email_verified"] == true
      assert signed_in_user(browser)["email_verified"] == true
    end

    test "sends nothing to verified or unknown emails, and answers the same", %{browser: browser} do
      _browser = request(browser, "nobody@example.com", "email-verification")
      refute_received {:otp, _email, _type, _otp}
    end
  end

  describe "passwords" do
    test "reset with a code, then sign in with the new password", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn} = post(browser, "/forget-password/email-otp", %{email: "ada@example.com"})
      assert json(conn) == %{"success" => true}
      otp = received_code("ada@example.com", :forget_password)

      {browser, conn} =
        post(browser, "/email-otp/reset-password", %{
          email: "ada@example.com",
          otp: otp,
          password: "a new password"
        })

      assert json(conn) == %{"success" => true}

      {_browser, conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "a new password"})

      assert json(conn)["user"]["email_verified"] == true
    end

    test "unknown emails get the same answer and no code", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/forget-password/email-otp", %{email: "nobody@example.com"})

      assert json(conn) == %{"success" => true}
      refute_received {:otp, _email, _type, _otp}
    end

    test "short passwords are refused before the code is used", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn} = post(browser, "/forget-password/email-otp", %{email: "ada@example.com"})
      otp = received_code("ada@example.com", :forget_password)

      {browser, conn} =
        post(browser, "/email-otp/reset-password", %{
          email: "ada@example.com",
          otp: otp,
          password: "short"
        })

      assert json(conn)["error"]["code"] == "password_too_short"

      {_browser, conn} =
        post(browser, "/email-otp/reset-password", %{
          email: "ada@example.com",
          otp: otp,
          password: "long enough now"
        })

      assert json(conn) == %{"success" => true}
    end
  end

  describe "changing the email" do
    test "with a code sent to the new address", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {browser, conn} =
        post(browser, "/email-otp/request-email-change", %{new_email: "ada@new.example"})

      assert json(conn) == %{"success" => true}
      otp = received_code("ada@new.example", :change_email)

      {browser, conn} =
        post(browser, "/email-otp/change-email", %{new_email: "ada@new.example", otp: otp})

      assert json(conn)["user"]["email"] == "ada@new.example"
      assert signed_in_user(browser)["email_verified"] == true
    end

    test "the code only works for the user who asked", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {_browser, _conn} =
        post(browser, "/email-otp/request-email-change", %{new_email: "ada@new.example"})

      otp = received_code("ada@new.example", :change_email)

      {other, _user} = sign_up(Browser.new(Auth), %{email: "eve@example.com"})

      {_other, conn} =
        post(other, "/email-otp/change-email", %{new_email: "ada@new.example", otp: otp})

      assert json(conn)["error"]["code"] == "invalid_otp"
    end

    test "not to an email someone has", %{browser: browser} do
      {_other, _user} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
      {browser, _user} = sign_up(browser)

      {_browser, conn} =
        post(browser, "/email-otp/request-email-change", %{new_email: "grace@example.com"})

      assert json(conn)["error"]["code"] == "user_already_exists"
      refute_received {:otp, _email, _type, _otp}
    end
  end
end

defmodule Authmk.EmailOTPOptionsTest do
  use Authmk.EmulationCase, async: true

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        {Authmk.Plugins.EmailPassword, require_email_verification: true},
        {Authmk.Plugins.EmailOTP,
         send_otp: &__MODULE__.send_otp/2,
         disable_sign_up: true,
         override_default_email_verification: true}
      ]

    def send_otp(%{email: email, otp: otp, type: type}, _ctx),
      do: send(self(), {:otp, email, type, otp})

    @impl Authmk
    def send_verification_email(_link, _ctx), do: send(self(), :verification_link)
  end

  @moduletag auth: Auth

  test "sign-up sends a code instead of a link, and the code verifies", %{browser: browser} do
    {browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json(conn) == %{"status" => true}
    refute_received :verification_link
    assert_received {:otp, "ada@example.com", :email_verification, otp}

    {browser, _conn} =
      post(browser, "/email-otp/verify-email", %{email: "ada@example.com", otp: otp})

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert json(conn)["user"]["email_verified"] == true
  end

  test "with sign-up off, unknown emails get no sign-in code", %{browser: browser} do
    {_browser, conn} =
      post(browser, "/email-otp/send-verification-otp", %{
        email: "nobody@example.com",
        type: "sign-in"
      })

    assert json(conn) == %{"success" => true}
    refute_received {:otp, _email, _type, _otp}
  end
end
