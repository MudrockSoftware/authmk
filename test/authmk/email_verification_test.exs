defmodule Authmk.EmailVerificationTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [{Authmk.Plugins.EmailPassword, require_email_verification: true}],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    email_verification: [send_on_sign_in: true, auto_sign_in_after_verification: true],
    user: [change_email: [enabled: true]]

  @impl Authmk
  def send_verification_email(link, _ctx), do: send(self(), {:email, :verification, link})

  @impl Authmk
  def send_change_email_verification(link, _ctx), do: send(self(), {:email, :change_email, link})

  @impl Authmk
  def before_email_verification(user, _ctx),
    do: send(self(), {:before_verification, user.email_verified})

  @impl Authmk
  def on_existing_user_sign_up(%{user: user}, _ctx),
    do: send(self(), {:email, :existing_user, user})
end

defmodule Authmk.EmailVerificationTest.ConfirmCurrentAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [{Authmk.Plugins.EmailPassword, require_email_verification: true}],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    email_verification: [auto_sign_in_after_verification: true],
    user: [change_email: [enabled: true, confirm_current_email: true]]

  @impl Authmk
  def send_verification_email(link, _ctx), do: send(self(), {:email, :verification, link})

  @impl Authmk
  def send_change_email_confirmation(link, _ctx),
    do: send(self(), {:email, :change_confirmation, link})

  @impl Authmk
  def send_change_email_verification(link, _ctx), do: send(self(), {:email, :change_email, link})
end

defmodule Authmk.EmailVerificationTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  @moduletag auth: Authmk.EmailVerificationTest.Auth

  @sign_up %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  test "sign-up sends a link, sign-in waits for it, the link verifies and signs in", %{
    browser: browser
  } do
    {browser, conn} =
      post(browser, "/sign-up/email", Map.put(@sign_up, :callback_url, "/welcome"))

    assert json(conn) == %{"status" => true}
    assert cookie(browser, "authmk.session_token") == nil
    link = assert_email(:verification)
    assert link.url =~ "http://localhost:4000/auth/verify-email?token="

    {browser, conn} = post(browser, "/sign-in/email", Map.take(@sign_up, [:email, :password]))
    assert conn.status == 403
    assert json(conn)["error"]["code"] == "email_not_verified"
    _resent = assert_email(:verification)

    {browser, conn} =
      get(browser, "/verify-email", %{token: link.token, callback_url: "/welcome"})

    assert redirected_to(conn) == "/welcome"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email_verified"] == true
  end

  test "an existing email gets the same sign-up answer, and the owner is told", %{
    browser: browser
  } do
    {_browser, first} = post(browser, "/sign-up/email", @sign_up)
    _link = assert_email(:verification)

    {_browser, second} = post(browser, "/sign-up/email", @sign_up)

    assert second.status == first.status
    assert json(second) == json(first)
    assert_email(:existing_user)
  end

  test "a bad token redirects back with an error", %{browser: browser} do
    {_browser, conn} = get(browser, "/verify-email", %{token: "nope", callback_url: "/welcome"})
    assert redirected_to(conn) == "/welcome?error=invalid_token"

    {_browser, conn} = get(browser, "/verify-email", %{token: "nope"})
    assert json(conn)["error"]["code"] == "invalid_token"
  end

  test "an expired token doesn't verify", %{browser: browser} do
    {_browser, _conn} = post(browser, "/sign-up/email", @sign_up)
    link = assert_email(:verification)

    Repo.update_all("verifications",
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    {_browser, conn} = get(browser, "/verify-email", %{token: link.token})
    assert json(conn)["error"]["code"] == "invalid_token"
  end

  test "send-verification-email answers the same for unknown emails", %{browser: browser} do
    {_browser, conn} = post(browser, "/send-verification-email", %{email: "nobody@example.com"})
    assert json(conn) == %{"status" => true}
    refute_received {:email, :verification, _}

    {_browser, _conn} = post(browser, "/sign-up/email", @sign_up)
    _link = assert_email(:verification)

    {_browser, conn} = post(browser, "/send-verification-email", %{email: "ada@example.com"})
    assert json(conn) == %{"status" => true}
    assert_email(:verification)
  end

  test "changing a verified email waits for the new address to confirm", %{browser: browser} do
    browser = verified_user(browser)

    {browser, conn} = post(browser, "/change-email", %{new_email: "ada@new.example"})
    assert json(conn) == %{"status" => true}
    link = assert_email(:change_email)
    assert link.new_email == "ada@new.example"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    {browser, _conn} = get(browser, "/verify-email", %{token: link.token})
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@new.example"
    assert json(conn)["user"]["email_verified"] == true
  end

  @tag auth: Authmk.EmailVerificationTest.ConfirmCurrentAuth
  test "with confirm_current_email, the current address approves first", %{browser: browser} do
    browser = verified_user(browser)

    {browser, _conn} = post(browser, "/change-email", %{new_email: "ada@new.example"})
    refute_received {:email, :change_email, _}
    confirmation = assert_email(:change_confirmation)
    assert confirmation.user.email == "ada@example.com"

    # The link works from any device; it is bound to the user, not the session.
    {_other_device, conn} =
      get(%{browser | cookies: %{}}, "/change-email/confirm", %{token: confirmation.token})

    assert json(conn) == %{"status" => true}
    link = assert_email(:change_email)

    {browser, _conn} = get(browser, "/verify-email", %{token: link.token})
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@new.example"
  end

  test "can't change to an email that's taken", %{browser: browser} do
    {_browser, _conn} = post(browser, "/sign-up/email", %{@sign_up | email: "bob@example.com"})
    _link = assert_email(:verification)
    browser = verified_user(browser)

    {_browser, conn} = post(browser, "/change-email", %{new_email: "bob@example.com"})
    assert json(conn)["error"]["code"] == "email_cannot_be_updated"
  end

  defp verified_user(browser) do
    {_browser, _conn} = post(browser, "/sign-up/email", @sign_up)
    link = assert_email(:verification)
    {browser, _conn} = get(browser, "/verify-email", %{token: link.token})
    browser
  end
end
