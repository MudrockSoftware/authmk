defmodule Authmk.TestingTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Testing
  alias Authmk.Testing.Inbox

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.EmailOTP, send_otp: &Inbox.deliver/2},
        {Authmk.Plugins.MagicLink, send_magic_link: &Inbox.deliver/2}
      ]

    # Background sends (the default): the inbox still finds the test.
    @impl Authmk
    def send_reset_password(message, ctx), do: Inbox.deliver(message, ctx)
  end

  @moduletag auth: Auth

  defp get_session(conn) do
    conn = Auth.call(%{conn | method: "GET", path_info: ["get-session"]}, Auth.init([]))
    json(conn)
  end

  test "a created user signs in with their password", %{browser: browser} do
    user =
      Testing.create_user(Auth, email: "Ada@Example.com", password: "correct horse", name: "Ada")

    assert user.email == "ada@example.com"
    assert user.email_verified
    assert Testing.get_user_by(Auth, email: "ADA@example.com").id == user.id

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert json(conn)["user"]["name"] == "Ada"

    # Unique defaults, and no password unless asked.
    other = Testing.create_user(Auth)
    assert other.email != user.email

    assert_raise ArgumentError, ~r/couldn't create the user/, fn ->
      Testing.create_user(Auth, email: "ada@example.com")
    end
  end

  test "sign_in/3 puts a working session on a test conn" do
    user = Testing.create_user(Auth)
    conn = Plug.Test.conn(:get, "/") |> Testing.sign_in(Auth, user)

    assert get_session(conn)["user"]["id"] == to_string(user.id)
    assert [session] = Testing.list_sessions(Auth, user)

    # Sessions without remember me get the browser-session cookie too.
    %{cookies: cookies} = Testing.create_session(Auth, user, remember_me: false)
    assert Map.has_key?(cookies, "authmk.dont_remember")
    assert length(Testing.list_sessions(Auth, user)) == 2
    assert session.user_id == user.id
  end

  test "the inbox catches codes and links, in the request or a background task", %{
    browser: browser
  } do
    Testing.create_user(Auth, email: "ada@example.com", password: "correct horse")

    {browser, _conn} =
      post(browser, "/email-otp/send-verification-otp", %{
        email: "ada@example.com",
        type: "sign-in"
      })

    {browser, _conn} = post(browser, "/sign-in/magic-link", %{email: "bob@example.com"})

    # Picked by recipient; the other message waits its turn.
    %{url: url} = Inbox.receive!(to: "bob@example.com")
    assert url =~ "/magic-link/verify?token="
    %{otp: code} = Inbox.receive!(to: "ada@example.com")
    assert Inbox.empty?()

    {browser, conn} = post(browser, "/sign-in/email-otp", %{email: "ada@example.com", otp: code})
    assert json(conn)["user"]["email"] == "ada@example.com"

    {_browser, _conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
    assert %{user: %{email: "ada@example.com"}, url: _} = Inbox.receive!(timeout: 1000)

    assert_raise RuntimeError, ~r/no authmk message for eve@example.com/, fn ->
      Inbox.receive!(to: "eve@example.com", timeout: 10)
    end
  end
end
