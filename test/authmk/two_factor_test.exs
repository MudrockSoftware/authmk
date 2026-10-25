defmodule Authmk.TwoFactorTest do
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
      app_name: "Acme",
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, send_otp: &__MODULE__.send_otp/2}
      ]

    def send_otp(%{user: user, otp: otp}, _ctx), do: send(self(), {:otp, user.email, otp})
  end

  @moduletag auth: Auth

  @password "correct horse"

  # The authenticator app: reads the secret from the otpauth URI.
  defp secret(uri),
    do:
      uri
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

  # A code for this period, or `periods` before.
  defp code(secret, periods \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) - periods * 30)

  # Signs up, turns 2FA on (confirmed with last period's code, so this
  # period's is still unused) and signs out. Returns the secret and backup codes.
  defp sign_up_with_two_factor(browser) do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/two-factor/enable", %{password: @password})
    %{"totp_uri" => uri, "backup_codes" => codes} = json(conn)
    secret = secret(uri)

    {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret, 1)})
    assert json(conn)["user"]["two_factor_enabled"] == true

    {browser, _conn} = post(browser, "/sign-out")
    {browser, secret, codes}
  end

  defp sign_in(browser) do
    post(browser, "/sign-in/email", %{email: "ada@example.com", password: @password})
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  describe "turning it on" do
    test "gives an authenticator URI and backup codes, and is on after a first code", %{
      browser: browser
    } do
      {browser, _user} = sign_up(browser)

      {browser, conn} = post(browser, "/two-factor/enable", %{password: @password})
      %{"totp_uri" => uri, "backup_codes" => codes} = json(conn)

      assert uri =~ "otpauth://totp/Acme:ada@example.com?"
      assert uri =~ "issuer=Acme"
      assert length(codes) == 10
      assert Enum.all?(codes, &(&1 =~ ~r/^[A-Z2-9]{5}-[A-Z2-9]{5}$/))

      # Not on until the user proves the app works.
      assert signed_in_user(browser)["two_factor_enabled"] == false

      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: "000000"})
      assert json(conn)["error"]["code"] == "invalid_two_factor_code"

      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret(uri))})
      assert json(conn)["status"] == true
      assert signed_in_user(browser)["two_factor_enabled"] == true

      # The secret and codes are stored encrypted.
      [%{secret: stored, backup_codes: stored_codes}] =
        Repo.all(
          from(t in "two_factors", select: %{secret: t.secret, backup_codes: t.backup_codes})
        )

      refute stored =~
               uri
               |> URI.parse()
               |> Map.fetch!(:query)
               |> URI.decode_query()
               |> Map.fetch!("secret")

      refute stored_codes =~ hd(codes)
    end

    test "takes the password", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {browser, conn} = post(browser, "/two-factor/enable", %{password: "wrong"})
      assert json(conn)["error"]["code"] == "invalid_password"

      {_browser, conn} = post(browser, "/two-factor/enable")
      assert json(conn)["error"]["code"] == "invalid_password"
      assert Repo.aggregate("two_factors", :count) == 0
    end

    test "with a one-time code instead of the app", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn} = post(browser, "/two-factor/enable", %{password: @password})

      {browser, _conn} = post(browser, "/two-factor/send-otp")
      assert_received {:otp, "ada@example.com", otp}

      {browser, conn} = post(browser, "/two-factor/verify-otp", %{code: otp})
      assert json(conn)["status"] == true
      assert signed_in_user(browser)["two_factor_enabled"] == true
    end
  end

  describe "signing in" do
    test "a password alone gets a challenge, not a session", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)

      {browser, conn} = sign_in(browser)

      assert json(conn) == %{
               "two_factor_redirect" => true,
               "two_factor_methods" => ["totp", "otp", "backup_code"]
             }

      assert signed_in_user(browser) == nil

      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret)})
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert signed_in_user(browser)["email"] == "ada@example.com"
    end

    test "an authenticator code works once", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)
      code = code(secret)

      {browser, _conn} = sign_in(browser)
      {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code})
      {browser, _conn} = post(browser, "/sign-out")

      {browser, _conn} = sign_in(browser)
      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: code})
      assert json(conn)["error"]["code"] == "invalid_two_factor_code"
      assert signed_in_user(browser) == nil
    end

    test "too many wrong codes end the challenge", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)

      browser =
        Enum.reduce(1..4, browser, fn _attempt, browser ->
          {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: "000000"})
          assert json(conn)["error"]["code"] == "invalid_two_factor_code"
          browser
        end)

      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: "000000"})
      assert conn.status == 429
      assert json(conn)["error"]["code"] == "too_many_two_factor_attempts"

      # Even the right code is too late now.
      {browser, conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret)})
      assert json(conn)["error"]["code"] == "two_factor_expired"
      assert signed_in_user(browser) == nil
    end

    test "a challenge cookie from another browser is no use", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)
      {_browser, _conn} = sign_in(browser)

      # The attacker knows the code but never passed the password step.
      {stranger, conn} = post(Browser.new(Auth), "/two-factor/verify-totp", %{code: code(secret)})
      assert json(conn)["error"]["code"] == "two_factor_expired"
      assert signed_in_user(stranger) == nil
    end

    test "with a one-time code", %{browser: browser} do
      {browser, _secret, _codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)

      {browser, conn} = post(browser, "/two-factor/send-otp")
      assert json(conn) == %{"status" => true}
      assert_received {:otp, "ada@example.com", otp}

      {browser, conn} = post(browser, "/two-factor/verify-otp", %{code: "000000"})
      assert json(conn)["error"]["code"] == "invalid_two_factor_code"

      {browser, conn} = post(browser, "/two-factor/verify-otp", %{code: otp})
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert signed_in_user(browser)["email"] == "ada@example.com"
    end

    test "a new one-time code replaces the old one", %{browser: browser} do
      {browser, _secret, _codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)

      {browser, _conn} = post(browser, "/two-factor/send-otp")
      assert_received {:otp, _email, first}
      {browser, _conn} = post(browser, "/two-factor/send-otp")
      assert_received {:otp, _email, second}

      if first != second do
        {browser, conn} = post(browser, "/two-factor/verify-otp", %{code: first})
        assert json(conn)["error"]["code"] == "invalid_two_factor_code"
        {_browser, conn} = post(browser, "/two-factor/verify-otp", %{code: second})
        assert json(conn)["user"]
      end
    end

    test "with a backup code, which is then used up", %{browser: browser} do
      {browser, _secret, [backup_code | _rest]} = sign_up_with_two_factor(browser)

      {browser, _conn} = sign_in(browser)
      # Lowercase and without the dash works too.
      typed = backup_code |> String.downcase() |> String.replace("-", "")
      {browser, conn} = post(browser, "/two-factor/verify-backup-code", %{code: typed})
      assert json(conn)["user"]["email"] == "ada@example.com"

      {browser, conn} = post(browser, "/two-factor/view-backup-codes", %{password: @password})
      assert length(json(conn)["backup_codes"]) == 9
      refute backup_code in json(conn)["backup_codes"]

      {browser, _conn} = post(browser, "/sign-out")
      {browser, _conn} = sign_in(browser)
      {_browser, conn} = post(browser, "/two-factor/verify-backup-code", %{code: backup_code})
      assert json(conn)["error"]["code"] == "invalid_two_factor_code"
    end

    test "a trusted device skips the challenge until 2FA is set up again", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)

      {browser, _conn} = sign_in(browser)

      {browser, _conn} =
        post(browser, "/two-factor/verify-totp", %{code: code(secret), trust_device: true})

      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn} = sign_in(browser)
      assert json(conn)["user"]["email"] == "ada@example.com"

      # Off and on again: the old trust is gone.
      {browser, _conn} = post(browser, "/two-factor/disable", %{password: @password})
      {browser, conn} = post(browser, "/two-factor/enable", %{password: @password})
      new_secret = secret(json(conn)["totp_uri"])
      {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code(new_secret)})
      {browser, _conn} = post(browser, "/sign-out")

      {_browser, conn} = sign_in(browser)
      assert json(conn)["two_factor_redirect"] == true
    end
  end

  describe "managing it" do
    test "turning it off takes the password, and sign-in is one step again", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)
      {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret)})

      {browser, conn} = post(browser, "/two-factor/disable", %{password: "wrong"})
      assert json(conn)["error"]["code"] == "invalid_password"

      {browser, conn} = post(browser, "/two-factor/disable", %{password: @password})
      assert json(conn) == %{"status" => true}
      assert Repo.aggregate("two_factors", :count) == 0

      {browser, _conn} = post(browser, "/sign-out")
      {_browser, conn} = sign_in(browser)
      assert json(conn)["user"]["two_factor_enabled"] == false
    end

    test "new backup codes replace the old ones", %{browser: browser} do
      {browser, secret, old_codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)
      {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret)})

      {browser, conn} = post(browser, "/two-factor/generate-backup-codes", %{password: @password})
      new_codes = json(conn)["backup_codes"]
      assert length(new_codes) == 10
      assert MapSet.disjoint?(MapSet.new(new_codes), MapSet.new(old_codes))

      {browser, _conn} = post(browser, "/sign-out")
      {browser, _conn} = sign_in(browser)
      {_browser, conn} = post(browser, "/two-factor/verify-backup-code", %{code: hd(old_codes)})
      assert json(conn)["error"]["code"] == "invalid_two_factor_code"
    end

    test "the authenticator URI again, with the password", %{browser: browser} do
      {browser, secret, _codes} = sign_up_with_two_factor(browser)
      {browser, _conn} = sign_in(browser)
      {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code(secret)})

      {_browser, conn} = post(browser, "/two-factor/get-totp-uri", %{password: @password})
      assert secret(json(conn)["totp_uri"]) == secret
    end

    test "needs a signed-in user", %{browser: browser} do
      for path <- ["/two-factor/enable", "/two-factor/disable", "/two-factor/view-backup-codes"] do
        {_browser, conn} = post(browser, path, %{password: @password})
        assert conn.status == 401
      end
    end
  end
end

defmodule Authmk.TwoFactorSocialTest do
  # Social sign-in with 2FA, for users without a password.
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.FakeProvider

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        {Authmk.Plugins.TwoFactor,
         skip_verification_on_enable: true,
         allow_passwordless: true,
         two_factor_page: "/two-factor",
         issuer: "Acme Social"}
      ],
      social_providers: [github: [client_id: "github-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  setup do
    FakeProvider.stub(Auth,
      profile: %{"id" => 1, "login" => "ada", "name" => "Ada", "email" => "ada@example.com"},
      emails: [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]
    )

    :ok
  end

  defp sign_in_with_github(browser) do
    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "github", callback_url: "/home"})

    get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))
  end

  test "the redirect goes to the 2FA page, which finishes the sign-in", %{browser: browser} do
    {browser, _conn} = sign_in_with_github(browser)

    # No password: a fresh session confirms. And no first code needed.
    {browser, conn} = post(browser, "/two-factor/enable")
    %{"totp_uri" => uri} = json(conn)
    assert uri =~ "issuer=Acme%20Social"

    secret =
      uri
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

    {browser, _conn} = post(browser, "/sign-out")
    {browser, conn} = sign_in_with_github(browser)
    assert redirected_to(conn) == "/two-factor"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil

    {browser, conn} =
      post(browser, "/two-factor/verify-totp", %{code: NimbleTOTP.verification_code(secret)})

    assert json(conn)["user"]["email"] == "ada@example.com"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["two_factor_enabled"] == true
  end

  test "one-time codes are off without a sender", %{browser: browser} do
    {browser, _conn} = sign_in_with_github(browser)
    {_browser, conn} = post(browser, "/two-factor/send-otp")
    assert json(conn)["error"]["code"] == "feature_disabled"
  end
end
