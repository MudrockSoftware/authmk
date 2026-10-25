defmodule Authmk.SecurityTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    trusted_origins: ["https://app.example.com"],
    background: :inline,
    rate_limit: [rules: %{"/get-session" => false, "/ok" => [window: 60, max: 2]}]
end

defmodule Authmk.SecurityTest.ProxyAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "https://example.com",
    background: :inline,
    advanced: [ip_address_headers: ["x-forwarded-for"]]
end

defmodule Authmk.SecurityTest do
  use Authmk.EmulationCase, async: true

  @moduletag auth: Authmk.SecurityTest.Auth

  @credentials %{email: "ada@example.com", password: "correct horse"}

  describe "origin checks" do
    test "rejects POSTs from untrusted origins", %{browser: browser} do
      {_browser, conn} =
        post(%{browser | origin: "https://evil.example"}, "/sign-in/email", @credentials)

      assert conn.status == 403
      assert json(conn)["error"]["code"] == "invalid_origin"
    end

    test "accepts trusted origins", %{browser: browser} do
      {_browser, conn} =
        post(
          %{browser | origin: "https://app.example.com"},
          "/sign-up/email",
          Map.put(@credentials, :name, "Ada")
        )

      assert conn.status == 200
    end

    test "rejects cookie-carrying POSTs that hide their origin", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {_browser, conn} = post(%{browser | origin: nil}, "/sign-out")

      assert json(conn)["error"]["code"] == "invalid_origin"
    end

    test "accepts POSTs without cookies or origin, as API clients send", %{browser: browser} do
      {_browser, conn} =
        post(%{browser | origin: nil}, "/sign-up/email", Map.put(@credentials, :name, "Ada"))

      assert conn.status == 200
    end

    test "rejects the literal null origin", %{browser: browser} do
      {_browser, conn} = post(%{browser | origin: "null"}, "/sign-in/email", @credentials)
      assert json(conn)["error"]["code"] == "invalid_origin"
    end
  end

  describe "redirect targets" do
    test "allows relative paths and trusted origins only", %{browser: browser} do
      verify = fn url -> get(browser, "/verify-email", %{token: "bad", callback_url: url}) end

      for url <- ["/home", "https://app.example.com/home", "http://localhost:4000/x"] do
        {_browser, conn} = verify.(url)

        assert redirected_to(conn) == url <> "?error=invalid_token",
               "expected #{url} to be allowed"
      end

      for url <- [
            "//evil.example",
            "https://evil.example",
            "/\\evil.example",
            "javascript:alert(1)",
            "https://app.example.com.evil.example",
            "/home\n"
          ] do
        {_browser, conn} = verify.(url)

        assert json(conn)["error"]["code"] == "invalid_callback_url",
               "expected #{inspect(url)} to be rejected"
      end
    end
  end

  describe "rate limits" do
    test "sign-in allows 3 attempts per 10 seconds", %{browser: browser} do
      statuses =
        for _ <- 1..4 do
          {_browser, conn} = post(browser, "/sign-in/email", @credentials)
          conn.status
        end

      assert statuses == [401, 401, 401, 429]

      {_browser, conn} = post(browser, "/sign-in/email", @credentials)
      assert json(conn)["error"]["code"] == "rate_limited"
      assert [retry_after] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..10
    end

    test "config rules override endpoint defaults", %{browser: browser} do
      statuses = for _ <- 1..3, do: elem(get(browser, "/ok"), 1).status
      assert statuses == [200, 200, 429]

      statuses = for _ <- 1..150, do: elem(get(browser, "/get-session"), 1).status
      assert Enum.all?(statuses, &(&1 == 200))
    end
  end

  describe "behind a proxy" do
    @describetag auth: Authmk.SecurityTest.ProxyAuth

    test "reads the client IP from the configured header", %{browser: browser} do
      browser = %{
        browser
        | origin: "https://example.com",
          headers: [{"x-forwarded-for", "203.0.113.7, 10.0.0.1"}]
      }

      {browser, _user} = sign_up(browser)

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["session"]["ip_address"] == "203.0.113.7"
    end

    test "uses secure, prefixed cookies on HTTPS", %{browser: browser} do
      {_browser, conn} =
        post(
          %{browser | origin: "https://example.com"},
          "/sign-up/email",
          Map.put(@credentials, :name, "Ada")
        )

      assert %{secure: true} = conn.resp_cookies["__Secure-authmk.session_token"]
    end
  end

  test "ignores proxy headers unless configured", %{browser: browser} do
    browser = %{browser | headers: [{"x-forwarded-for", "203.0.113.7"}]}
    {browser, _user} = sign_up(browser)

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["session"]["ip_address"] == "127.0.0.1"
  end

  test "unknown paths are 404", %{browser: browser} do
    {_browser, conn} = get(browser, "/nope")
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "not_found"
  end
end
