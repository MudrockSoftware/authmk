defmodule Authmk.EmailPasswordTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.EmailPasswordTest.ResetPageAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [{Authmk.Plugins.EmailPassword, reset_password_page: "/account/new-password"}],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.EmailPasswordTest.BcryptAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    password_hasher: Authmk.Password.Bcrypt,
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.EmailPasswordTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.EmailPasswordTest.Auth
  alias Authmk.Plugins.EmailPassword
  alias Authmk.Test.Repo

  @moduletag auth: Authmk.EmailPasswordTest.Auth

  describe "sign up" do
    test "creates the user, signs them in and sets an HttpOnly session cookie", %{
      browser: browser
    } do
      {browser, conn} =
        post(browser, "/sign-up/email", %{
          email: "  Ada@Example.com ",
          password: "correct horse",
          name: "Ada"
        })

      assert conn.status == 200
      user = json(conn)["user"]
      assert user["email"] == "ada@example.com"
      assert user["name"] == "Ada"
      assert user["email_verified"] == false
      refute Map.has_key?(user, "password")

      assert %{http_only: true, same_site: "Lax"} = conn.resp_cookies["authmk.session_token"]

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"
    end

    test "rejects a taken email", %{browser: browser} do
      {_signed_in, _user} = sign_up(browser)

      {_browser, conn} =
        post(browser, "/sign-up/email", %{
          email: "ada@example.com",
          password: "another one",
          name: "X"
        })

      assert conn.status == 422
      assert json(conn)["error"]["code"] == "user_already_exists"
    end

    test "rejects short passwords and invalid emails", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/sign-up/email", %{email: "ada@example.com", password: "short", name: "A"})

      assert json(conn)["error"]["code"] == "password_too_short"

      {_browser, conn} =
        post(browser, "/sign-up/email", %{
          email: "not-an-email",
          password: "long enough",
          name: "A"
        })

      assert json(conn)["error"]["code"] == "invalid_email"
    end

    test "can't set fields that don't accept input", %{browser: browser} do
      {_browser, user} = sign_up(browser, %{email_verified: true})
      assert user["email_verified"] == false
    end

    test "reports missing params as field errors", %{browser: browser} do
      {_browser, conn} = post(browser, "/sign-up/email", %{email: "ada@example.com"})

      assert conn.status == 422
      assert json(conn)["error"]["details"]["fields"]["password"] == ["can't be blank"]
    end
  end

  describe "sign in" do
    setup %{browser: browser} do
      {_signed_in, _user} = sign_up(browser)
      :ok
    end

    test "with the right password", %{browser: browser} do
      {browser, conn} =
        post(browser, "/sign-in/email", %{email: "ADA@example.com", password: "correct horse"})

      assert conn.status == 200
      assert json(conn)["user"]["email"] == "ada@example.com"

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["session"]["user_id"] == json(conn)["user"]["id"]
    end

    test "fails the same way for a wrong password and an unknown email", %{browser: browser} do
      {_browser, wrong_password} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "wrong password"})

      {_browser, unknown_email} =
        post(browser, "/sign-in/email", %{email: "bob@example.com", password: "correct horse"})

      assert wrong_password.status == 401
      assert unknown_email.status == 401
      assert json(wrong_password) == json(unknown_email)
      assert json(wrong_password)["error"]["code"] == "invalid_credentials"
    end

    test "without remember me, the cookie lasts for the browser session only", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/sign-in/email", %{
          email: "ada@example.com",
          password: "correct horse",
          remember_me: false
        })

      refute Map.has_key?(conn.resp_cookies["authmk.session_token"], :max_age)
      marker = conn.resp_cookies["authmk.dont_remember"].value
      assert {:ok, "true"} = Authmk.Crypto.verify(Auth.config(), "dont-remember", marker)
    end

    test "rejects untrusted callback URLs", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/sign-in/email", %{
          email: "ada@example.com",
          password: "correct horse",
          callback_url: "https://evil.example/steal"
        })

      assert json(conn)["error"]["code"] == "invalid_callback_url"
    end
  end

  @tag auth: Authmk.EmailPasswordTest.BcryptAuth
  test "Bcrypt hashes work, for databases that already use them", %{browser: browser} do
    {_browser, _user} = sign_up(browser)
    assert ["$2b$" <> _] = Repo.all(from(a in "accounts", select: a.password))

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert conn.status == 200
  end

  # Bcrypt ignores everything after 72 bytes: "x" * 72 <> "anything" would all work.
  @tag auth: Authmk.EmailPasswordTest.BcryptAuth
  test "Bcrypt refuses new passwords it would cut short", %{browser: browser} do
    for password <- [String.duplicate("x", 73), String.duplicate("€", 25)] do
      {_browser, conn} =
        post(browser, "/sign-up/email", %{email: "ada@example.com", password: password})

      assert json(conn)["error"]["code"] == "password_too_long"
    end

    assert Repo.aggregate("users", :count) == 0
    {browser, _user} = sign_up(browser, %{password: String.duplicate("x", 72)})

    {browser, conn} =
      post(browser, "/change-password", %{
        current_password: String.duplicate("x", 72),
        new_password: String.duplicate("x", 72) <> "y"
      })

    assert json(conn)["error"]["code"] == "password_too_long"

    # A long password set before still signs in.
    long = String.duplicate("y", 100)
    Repo.update_all("accounts", set: [password: Bcrypt.hash_pwd_salt(long)])

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: long})

    assert conn.status == 200
  end

  test "set_password gives a password to a user without one, once", %{browser: browser} do
    # A user that signed up some other way, like a social provider.
    user = Repo.insert!(%Auth.User{name: "Ada", email: "ada@example.com"})

    assert {:error, %Authmk.Error{code: :password_too_short}} =
             EmailPassword.set_password(Auth, user, "short")

    assert {:ok, _account} =
             EmailPassword.set_password(Auth, user, "correct horse")

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert conn.status == 200

    assert {:error, %Authmk.Error{code: :password_already_set}} =
             EmailPassword.set_password(Auth, user, "another one")
  end

  test "sign out ends the session and clears the cookie", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/sign-out")

    assert json(conn) == %{"success" => true}
    assert cookie(browser, "authmk.session_token") == nil

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil
  end

  test "a stolen cookie stops working after sign-out", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    stolen = browser.cookies
    {_browser, _conn} = post(browser, "/sign-out")

    {_attacker, conn} = get(%{browser | cookies: stolen}, "/get-session")
    assert json(conn) == nil
  end

  describe "password reset" do
    test "full flow: request, open link, set new password, sign in", %{browser: browser} do
      {_signed_in, _user} = sign_up(browser)

      {_browser, conn} =
        post(browser, "/request-password-reset", %{
          email: "ada@example.com",
          redirect_to: "/reset"
        })

      assert json(conn) == %{"status" => true}
      link = assert_email(:reset_password)

      # The emailed link redirects to the app's reset page with the token.
      {_browser, conn} =
        get(browser, URI.parse(link.url).path |> String.replace_prefix("/auth", ""), %{
          callback_url: "/reset"
        })

      assert redirected_to(conn) == "/reset?token=#{link.token}"

      {_browser, conn} =
        post(browser, "/reset-password", %{token: link.token, new_password: "new password 1"})

      assert json(conn) == %{"status" => true}

      {_browser, conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "new password 1"})

      assert conn.status == 200

      {_browser, conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

      assert conn.status == 401
    end

    test "the token works only once", %{browser: browser} do
      {_signed_in, _user} = sign_up(browser)

      {_browser, _conn} =
        post(browser, "/request-password-reset", %{
          email: "ada@example.com",
          redirect_to: "/reset"
        })

      link = assert_email(:reset_password)

      {_browser, conn} =
        post(browser, "/reset-password", %{token: link.token, new_password: "new password 1"})

      assert conn.status == 200

      {_browser, conn} =
        post(browser, "/reset-password", %{token: link.token, new_password: "new password 2"})

      assert json(conn)["error"]["code"] == "invalid_token"
    end

    test "unknown emails get the same answer and no email", %{browser: browser} do
      {_browser, conn} =
        post(browser, "/request-password-reset", %{
          email: "nobody@example.com",
          redirect_to: "/reset"
        })

      assert json(conn) == %{"status" => true}
      refute_received {:email, :reset_password, _}
    end

    # Without redirect_to the link still opens a page, never a JSON error.
    test "a link requested without redirect_to ends on the error page", %{browser: browser} do
      {_signed_in, _user} = sign_up(browser)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          post(browser, "/request-password-reset", %{email: "ada@example.com"})
        end)

      assert log =~ "reset_password_page"
      link = assert_email(:reset_password)

      {_browser, conn} =
        get(browser, URI.parse(link.url).path |> String.replace_prefix("/auth", ""))

      assert redirected_to(conn) =~ "/auth/error?error=reset_password_page_missing"
    end
  end

  describe "password reset with a reset_password_page" do
    @describetag auth: Authmk.EmailPasswordTest.ResetPageAuth

    test "links requested without redirect_to open it", %{browser: browser} do
      {_signed_in, _user} =
        sign_up(browser)

      {_browser, _conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
      link = assert_email(:reset_password)

      {_browser, conn} =
        get(browser, URI.parse(link.url).path |> String.replace_prefix("/auth", ""))

      assert redirected_to(conn) == "/account/new-password?token=#{link.token}"

      # redirect_to still wins.
      {_browser, _conn} =
        post(browser, "/request-password-reset", %{
          email: "ada@example.com",
          redirect_to: "/reset"
        })

      link = assert_email(:reset_password)
      {path, query} = {URI.parse(link.url).path, URI.decode_query(URI.parse(link.url).query)}
      {_browser, conn} = get(browser, String.replace_prefix(path, "/auth", ""), query)
      assert redirected_to(conn) == "/reset?token=#{link.token}"
    end
  end

  test "change password checks the current one and can sign out other devices", %{
    browser: browser
  } do
    {laptop, _user} = sign_up(browser)

    {phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    {_laptop, conn} =
      post(laptop, "/change-password", %{
        current_password: "wrong",
        new_password: "new password 1"
      })

    assert json(conn)["error"]["code"] == "invalid_password"

    {laptop, conn} =
      post(laptop, "/change-password", %{
        current_password: "correct horse",
        new_password: "new password 1",
        revoke_other_sessions: true
      })

    assert conn.status == 200
    {_phone, conn} = get(phone, "/get-session")
    assert json(conn) == nil
    {_laptop, conn} = get(laptop, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
  end

  test "requests without a session are rejected where one is required", %{browser: browser} do
    {_browser, conn} =
      post(browser, "/change-password", %{current_password: "a", new_password: "bbbbbbbb"})

    assert conn.status == 401
    assert json(conn)["error"]["code"] == "unauthorized"
  end
end
