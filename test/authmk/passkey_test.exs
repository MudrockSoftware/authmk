defmodule Authmk.PasskeyTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}
  alias Authmk.Testing.FakeAuthenticator

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      app_name: "Acme",
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, skip_verification_on_enable: true},
        {Authmk.Plugins.Passkey, registration_extensions: %{"credProps" => true}}
      ]
  end

  @moduletag auth: Auth

  @icloud <<0xFB, 0xFC, 0x30, 0x07, 0x15, 0x4E, 0x4E, 0xCC, 0x8C, 0x0B, 0x6E, 0x02, 0x05, 0x57,
            0xD7, 0xBD>>

  defp register(browser, authenticator, params \\ %{}) do
    {browser, conn} = post(browser, "/passkey/generate-register-options", params)
    options = json(conn)
    response = FakeAuthenticator.register(authenticator, options)

    {browser, conn} =
      post(browser, "/passkey/verify-registration", Map.merge(%{response: response}, params))

    {browser, conn, options}
  end

  defp sign_in(browser, authenticator) do
    {browser, conn} = post(browser, "/passkey/generate-authenticate-options")
    options = json(conn)
    {authenticator, response} = FakeAuthenticator.authenticate(authenticator, options)
    {browser, conn} = post(browser, "/passkey/verify-authentication", %{response: response})
    {browser, conn, authenticator, options}
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  # Signs up with a password and registers a passkey, then signs out.
  defp user_with_passkey(browser, authenticator) do
    {browser, _user} = sign_up(browser)
    {browser, conn, _options} = register(browser, authenticator)
    assert json(conn)["passkey"]
    {browser, _conn} = post(browser, "/sign-out")
    browser
  end

  describe "registering" do
    test "gives WebAuthn options, and stores the passkey", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      authenticator = FakeAuthenticator.new(aaguid: @icloud, backup_eligible: true)

      {browser, conn, options} = register(browser, authenticator)

      assert options["rp"] == %{"id" => "localhost", "name" => "Acme"}
      assert options["user"]["name"] == "ada@example.com"
      assert options["attestation"] == "none"
      assert options["extensions"] == %{"credProps" => true}
      assert byte_size(Base.url_decode64!(options["challenge"], padding: false)) >= 16

      passkey = json(conn)["passkey"]
      assert passkey["name"] == "iCloud Keychain"
      assert passkey["device_type"] == "multi_device"
      assert passkey["backed_up"] == true
      assert passkey["transports"] == "internal,hybrid"
      refute Map.has_key?(passkey, "public_key")

      {_browser, conn} = get(browser, "/passkey/list-user-passkeys")
      assert [%{"name" => "iCloud Keychain"}] = json(conn)
    end

    test "a passkey registers once, and the next options exclude it", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      authenticator = FakeAuthenticator.new()
      {browser, _conn, _options} = register(browser, authenticator)

      {browser, conn, options} = register(browser, authenticator)
      assert [%{"type" => "public-key"}] = options["excludeCredentials"]
      assert json(conn)["error"]["code"] == "passkey_already_registered"
      assert Repo.aggregate("passkeys", :count) == 1
      _ = browser
    end

    test "needs a signed-in user", %{browser: browser} do
      {_browser, conn} = post(browser, "/passkey/generate-register-options")
      assert conn.status == 401
    end

    test "a response for another site is refused", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      phished = FakeAuthenticator.new(origin: "https://evil.example")

      {_browser, conn, _options} = register(browser, phished)
      assert json(conn)["error"]["code"] == "invalid_passkey"
      assert Repo.aggregate("passkeys", :count) == 0
    end
  end

  describe "signing in" do
    test "with a passkey, from options any passkey answers", %{browser: browser} do
      authenticator = FakeAuthenticator.new()
      browser = user_with_passkey(browser, authenticator)

      {browser, conn, _authenticator, options} = sign_in(browser, authenticator)
      assert options["rpId"] == "localhost"
      assert options["allowCredentials"] == []
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert signed_in_user(browser)["email"] == "ada@example.com"
    end

    test "a challenge works once", %{browser: browser} do
      authenticator = FakeAuthenticator.new()
      browser = user_with_passkey(browser, authenticator)

      {browser, conn} = post(browser, "/passkey/generate-authenticate-options")
      {_authenticator, response} = FakeAuthenticator.authenticate(authenticator, json(conn))
      challenge_cookie = Browser.cookie(browser, "authmk.passkey_challenge")

      {browser, _conn} = post(browser, "/passkey/verify-authentication", %{response: response})
      {browser, _conn} = post(browser, "/sign-out")

      # Replayed, cookie and all.
      replay = %{
        browser
        | cookies: Map.put(browser.cookies, "authmk.passkey_challenge", challenge_cookie)
      }

      {_replay, conn} = post(replay, "/passkey/verify-authentication", %{response: response})
      assert json(conn)["error"]["code"] == "passkey_challenge_expired"
    end

    test "unknown passkeys and other sites' responses are refused", %{browser: browser} do
      browser = user_with_passkey(browser, FakeAuthenticator.new())

      for stranger <- [
            FakeAuthenticator.new(),
            FakeAuthenticator.new(origin: "https://evil.example")
          ] do
        {browser, conn, _authenticator, _options} = sign_in(browser, stranger)
        assert json(conn)["error"]["code"] == "invalid_passkey"
        assert signed_in_user(browser) == nil
      end
    end

    test "a counter that goes backwards means a copied passkey", %{browser: browser} do
      authenticator = FakeAuthenticator.new()
      browser = user_with_passkey(browser, authenticator)

      {browser, _conn, _moved, _options} = sign_in(browser, authenticator)
      {browser, _conn} = post(browser, "/sign-out")

      # The copy still has the old count.
      {browser, conn, _moved, _options} = sign_in(browser, authenticator)
      assert json(conn)["error"]["code"] == "passkey_cloned"
      assert signed_in_user(browser) == nil
    end

    test "passkeys that don't count work every time", %{browser: browser} do
      authenticator = FakeAuthenticator.new(counts: false)
      browser = user_with_passkey(browser, authenticator)

      {browser, _conn, _same, _options} = sign_in(browser, authenticator)
      {browser, _conn} = post(browser, "/sign-out")
      {browser, conn, _same, _options} = sign_in(browser, authenticator)
      assert json(conn)["user"]
      assert signed_in_user(browser)
    end

    test "with 2FA on, a verified passkey is enough; an unverified one isn't", %{browser: browser} do
      verified = FakeAuthenticator.new()
      unverified = FakeAuthenticator.new(user_verified: false)

      {browser, _user} = sign_up(browser)
      {browser, _conn, _options} = register(browser, verified)
      {browser, _conn, _options} = register(browser, unverified)
      {browser, _conn} = post(browser, "/two-factor/enable", %{password: "correct horse"})
      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn, _authenticator, _options} = sign_in(browser, unverified)
      assert json(conn)["two_factor_redirect"] == true
      assert signed_in_user(browser) == nil

      {browser, conn, _authenticator, _options} = sign_in(browser, verified)
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert signed_in_user(browser)
    end

    test "signed-in users get their own passkeys as allowed credentials", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn, _options} = register(browser, FakeAuthenticator.new())

      {_browser, conn} = post(browser, "/passkey/generate-authenticate-options")

      assert [%{"type" => "public-key", "transports" => ["internal", "hybrid"]}] =
               json(conn)["allowCredentials"]
    end
  end

  describe "managing passkeys" do
    test "rename and delete your own, not others'", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, conn, _options} = register(browser, FakeAuthenticator.new(), %{name: "Laptop"})
      id = json(conn)["passkey"]["id"]
      assert json(conn)["passkey"]["name"] == "Laptop"

      {other, _user} = sign_up(Browser.new(Auth), %{email: "eve@example.com"})
      {other, conn} = post(other, "/passkey/update-passkey", %{id: id, name: "Mine now"})
      assert json(conn)["error"]["code"] == "passkey_not_found"
      {_other, conn} = post(other, "/passkey/delete-passkey", %{id: id})
      assert json(conn)["error"]["code"] == "passkey_not_found"

      {browser, conn} = post(browser, "/passkey/update-passkey", %{id: id, name: "Work laptop"})
      assert json(conn)["passkey"]["name"] == "Work laptop"

      {browser, conn} = post(browser, "/passkey/delete-passkey", %{id: id})
      assert json(conn) == %{"status" => true}
      {_browser, conn} = get(browser, "/passkey/list-user-passkeys")
      assert json(conn) == []
    end

    test "unknown ids are not found", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {_browser, conn} = post(browser, "/passkey/delete-passkey", %{id: "not-an-id"})
      assert json(conn)["error"]["code"] == "passkey_not_found"
    end
  end
end

defmodule Authmk.PasskeySignUpTest do
  # A passkey as the first sign-in method.
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}
  alias Authmk.Testing.FakeAuthenticator

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Passkey,
         sign_up: true, origin: "https://app.example.com", rp_id: "example.com"}
      ]
  end

  @moduletag auth: Auth

  test "a visitor signs up with a passkey, then signs in with it", %{browser: browser} do
    authenticator = FakeAuthenticator.new(origin: "https://app.example.com")

    {browser, conn} =
      post(browser, "/passkey/generate-register-options", %{email: "Ada@Example.com", name: "Ada"})

    options = json(conn)
    assert options["rp"]["id"] == "example.com"
    assert options["user"]["name"] == "ada@example.com"

    response = FakeAuthenticator.register(authenticator, options)
    {browser, conn} = post(browser, "/passkey/verify-registration", %{response: response})
    assert json(conn)["user"]["email"] == "ada@example.com"

    {browser, _conn} = post(browser, "/sign-out")

    {browser, conn} =
      post(browser, "/passkey/generate-authenticate-options", %{
        extensions: %{"prf" => %{"eval" => %{"first" => "c2FsdA"}}}
      })

    assert json(conn)["extensions"]["prf"]
    {_authenticator, response} = FakeAuthenticator.authenticate(authenticator, json(conn))
    {_browser, conn} = post(browser, "/passkey/verify-authentication", %{response: response})
    assert json(conn)["user"]["name"] == "Ada"
  end

  test "taken emails are refused", %{browser: browser} do
    {_other, _user} = sign_up(Browser.new(Auth))

    {_browser, conn} =
      post(browser, "/passkey/generate-register-options", %{email: "ada@example.com"})

    assert json(conn)["error"]["code"] == "user_already_exists"
  end

  test "an email is needed", %{browser: browser} do
    {_browser, conn} = post(browser, "/passkey/generate-register-options")
    assert json(conn)["error"]["code"] == "invalid_email"
    assert Repo.aggregate("users", :count) == 0
  end
end
