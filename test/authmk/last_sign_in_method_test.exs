defmodule Authmk.LastSignInMethodTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Authmk.Plugins.LastSignInMethod
  alias Authmk.Test.{Browser, FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [github: [client_id: "client-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.TwoFactor,
        {Authmk.Plugins.LastSignInMethod, store_in_database: true}
      ]
  end

  defmodule ConsentAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.LastSignInMethod,
         store_in_database: true, store_cookie: &__MODULE__.consent?/2}
      ]

    # Consent is a cookie of the app's own; a broken value blows up.
    def consent?(%{conn: conn}, _method) do
      case conn.req_cookies["consent"] do
        "yes" -> true
        "broken" -> raise "consent store down"
        _none -> false
      end
    end
  end

  defmodule CustomAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.LastSignInMethod, resolve_method: &__MODULE__.method/2}
      ]

    def method(:sign_up_email, _ctx), do: "invite"
    def method(_endpoint, _ctx), do: nil
  end

  @moduletag auth: Auth

  @cookie "authmk.last_sign_in_method"
  @password "correct horse"

  defp stored_method(email \\ "ada@example.com"),
    do: Repo.one(from(u in "users", where: u.email == ^email, select: u.last_sign_in_method))

  defp sign_in(browser),
    do: post(browser, "/sign-in/email", %{email: "ada@example.com", password: @password})

  defp server_side(browser, auth) do
    conn =
      Enum.reduce(browser.cookies, Plug.Test.conn(:get, "/sign-in"), fn {name, value}, conn ->
        Plug.Test.put_req_cookie(conn, name, value)
      end)

    LastSignInMethod.get(conn, auth)
  end

  test "email sign-in: a cookie scripts can read, and the user field", %{browser: browser} do
    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: @password,
        name: "Ada"
      })

    assert %{value: "email", http_only: false, max_age: 2_592_000} = conn.resp_cookies[@cookie]
    assert stored_method() == "email"

    # It outlives the session, for the next visit's sign-in page.
    {browser, _conn} =
      post(Browser.new(Auth), "/sign-in/email", %{email: "ada@example.com", password: @password})

    {browser, _conn} = post(browser, "/sign-out")
    assert cookie(browser, @cookie) == "email"
    assert server_side(browser, Auth) == "email"

    # A failed sign-in changes nothing.
    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "wrong"})

    assert conn.status == 401
    refute Map.has_key?(conn.resp_cookies, @cookie)
  end

  test "social sign-in records the provider", %{browser: browser} do
    # Someone else signed in with email on this device before.
    {browser, _user} = sign_up(browser, %{email: "bob@example.com"})
    {browser, _conn} = post(browser, "/sign-out")
    assert cookie(browser, @cookie) == "email"

    FakeProvider.stub(Auth,
      routes: %{
        "/user" => %{"id" => 1, "login" => "ada", "name" => "Ada", "email" => "ada@example.com"},
        "/user/emails" => [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]
      }
    )

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "github", callback_url: "/done"})

    {browser, conn} = get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) == "/done"

    assert cookie(browser, @cookie) == "github"
    assert stored_method() == "github"
  end

  test "with two-factor, the first step's method is recorded once it's done", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/two-factor/enable", %{password: @password})
    secret = json(conn)["totp_uri"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    secret = Base.decode32!(secret["secret"], padding: false)
    previous = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
    {_browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: previous})

    # A new device, and a stale value to show the record changes.
    Repo.update_all("users", set: [last_sign_in_method: "github"])
    {browser, conn} = sign_in(Browser.new(Auth))
    assert json(conn)["two_factor_redirect"] == true
    assert cookie(browser, @cookie) == nil
    assert stored_method() == "github"

    {browser, conn} =
      post(browser, "/two-factor/verify-totp", %{code: NimbleTOTP.verification_code(secret)})

    assert conn.status == 200
    assert cookie(browser, @cookie) == "email"
    assert cookie(browser, "authmk.pending_sign_in_method") == nil
    assert stored_method() == "email"
  end

  @tag auth: ConsentAuth
  test "without consent there is no cookie, and the sign-in goes on", %{browser: browser} do
    for {consent, email} <- [{nil, "bob@example.com"}, {"broken", "eve@example.com"}] do
      browser = if consent, do: %{browser | cookies: %{"consent" => consent}}, else: browser
      {{browser, _user}, log} = with_log(fn -> sign_up(browser, %{email: email}) end)
      if consent == "broken", do: assert(log =~ "store_cookie raised RuntimeError")
      assert cookie(browser, @cookie) == nil
      assert stored_method(email) == "email"
    end

    {_browser, _user} = sign_up(Browser.new(ConsentAuth))

    browser = %{Browser.new(ConsentAuth) | cookies: %{"consent" => "yes"}}
    {browser, _conn} = sign_in(browser)
    assert cookie(browser, @cookie) == "email"
  end

  @tag auth: CustomAuth
  test "custom methods, and the cookie only as a hint", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    assert cookie(browser, @cookie) == "invite"

    # Falls back to the built-in names.
    {browser, _conn} = post(browser, "/sign-out")
    {browser, _conn} = sign_in(browser)
    assert cookie(browser, @cookie) == "email"

    # The browser can write anything there; only plain names are read back.
    browser = %{browser | cookies: %{@cookie => "<script>"}}
    assert server_side(browser, CustomAuth) == nil
  end
end
