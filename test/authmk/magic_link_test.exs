defmodule Authmk.MagicLinkTest do
  use Authmk.EmulationCase, async: true

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
        {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2}
      ]

    def send_magic_link(%{email: email, url: url}, _ctx),
      do: send(self(), {:magic_link, email, url})
  end

  @moduletag auth: Auth

  defp request_link(browser, params) do
    {browser, conn} = post(browser, "/sign-in/magic-link", params)
    assert json(conn) == %{"status" => true}
    assert_received {:magic_link, _email, url}
    {browser, url}
  end

  # Opens the link in the browser.
  defp open(browser, url) do
    %URI{path: "/auth" <> path, query: query} = URI.parse(url)
    get(browser, path, URI.decode_query(query))
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  test "a new email signs up through the link", %{browser: browser} do
    {browser, url} =
      request_link(browser, %{
        email: "Ada@Example.com",
        name: "Ada",
        callback_url: "/dashboard",
        new_user_callback_url: "/welcome"
      })

    assert url =~ "http://localhost:4000/auth/magic-link/verify?token="

    {browser, conn} = open(browser, url)
    assert redirected_to(conn) == "/welcome"

    user = signed_in_user(browser)
    assert user["email"] == "ada@example.com"
    assert user["name"] == "Ada"
    assert user["email_verified"] == true
  end

  test "an existing user signs in, and their email is verified now", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, _conn} = post(browser, "/sign-out")

    {browser, url} =
      request_link(browser, %{email: "ada@example.com", callback_url: "/dashboard"})

    {browser, conn} = open(browser, url)
    assert redirected_to(conn) == "/dashboard"
    assert signed_in_user(browser)["email_verified"] == true
    assert Repo.aggregate("users", :count) == 1
  end

  test "a link works once", %{browser: browser} do
    {browser, url} =
      request_link(browser, %{
        email: "ada@example.com",
        callback_url: "/dashboard",
        error_callback_url: "/sign-in"
      })

    {browser, _conn} = open(browser, url)
    {browser, _conn} = post(browser, "/sign-out")

    {browser, conn} = open(browser, url)
    assert redirected_to(conn) == "/sign-in?error=invalid_token"
    assert signed_in_user(browser) == nil
  end

  test "without a callback URL, the answer is JSON", %{browser: browser} do
    {browser, url} = request_link(browser, %{email: "ada@example.com"})
    {_browser, conn} = open(browser, url)
    assert json(conn)["user"]["email"] == "ada@example.com"
  end

  test "callback URLs must be trusted, when asking and when opening", %{browser: browser} do
    {browser, conn} =
      post(browser, "/sign-in/magic-link", %{
        email: "ada@example.com",
        callback_url: "https://evil.example"
      })

    assert json(conn)["error"]["code"] == "invalid_callback_url"
    refute_received {:magic_link, _email, _url}

    # A link whose callback was changed afterwards.
    {browser, url} =
      request_link(browser, %{email: "ada@example.com", callback_url: "/dashboard"})

    tampered =
      String.replace(url, "callback_url=%2Fdashboard", "callback_url=https%3A%2F%2Fevil.example")

    {browser, conn} = open(browser, tampered)
    assert conn.status == 403
    assert signed_in_user(browser) == nil
  end

  defmodule TwoFactorAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, skip_verification_on_enable: true, two_factor_page: "/2fa"},
        {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2}
      ]

    def send_magic_link(%{email: email, url: url}, _ctx),
      do: send(self(), {:magic_link, email, url})
  end

  @tag auth: TwoFactorAuth
  test "two-factor authentication applies", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, _conn} = post(browser, "/two-factor/enable", %{password: "correct horse"})
    {browser, _conn} = post(browser, "/sign-out")

    {browser, url} =
      request_link(browser, %{email: "ada@example.com", callback_url: "/dashboard"})

    {browser, conn} = open(browser, url)
    assert redirected_to(conn) == "/2fa"
    assert signed_in_user(browser) == nil
  end
end

defmodule Authmk.MagicLinkOptionsTest do
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
        {Authmk.Plugins.MagicLink,
         send_magic_link: &__MODULE__.send_magic_link/2,
         disable_sign_up: true,
         generate_token: &__MODULE__.token/1}
      ]

    def send_magic_link(%{email: email, token: token}, _ctx),
      do: send(self(), {:magic_link, email, token})

    def token(email),
      do:
        "ml-" <>
          Base.url_encode64(:crypto.hash(:sha256, email <> Authmk.Token.generate()),
            padding: false
          )
  end

  @moduletag auth: Auth

  test "with sign-up off, unknown emails get the same answer and no link", %{browser: browser} do
    {_browser, conn} = post(browser, "/sign-in/magic-link", %{email: "nobody@example.com"})
    assert json(conn) == %{"status" => true}
    refute_received {:magic_link, _email, _token}
    assert Repo.aggregate("users", :count) == 0
  end

  test "known emails get a link with the app's token, stored hashed", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, _conn} = post(browser, "/sign-out")

    {browser, _conn} = post(browser, "/sign-in/magic-link", %{email: "ada@example.com"})
    assert_received {:magic_link, "ada@example.com", "ml-" <> _ = token}

    refute Enum.any?(
             Repo.all(from(v in "verifications", select: v.identifier)),
             &(&1 =~ token)
           )

    {_browser, conn} = get(browser, "/magic-link/verify", %{token: token})
    assert json(conn)["user"]["email"] == "ada@example.com"
  end
end
