defmodule Authmk.OneTimeTokenTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OneTimeToken
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.OneTimeToken]
  end

  defmodule ServerOnlyAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Bearer,
        {Authmk.Plugins.OneTimeToken,
         disable_client_request: true, disable_set_session_cookie: true}
      ]
  end

  @moduletag auth: Auth

  defp signed_in_email(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]["email"]
  end

  test "hand a signed-in user over to another device, once", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = get(browser, "/one-time-token/generate")
    token = json(conn)["token"]

    {other, conn} = post(Browser.new(Auth), "/one-time-token/verify", %{token: token})
    assert json(conn)["user"]["email"] == "ada@example.com"
    assert signed_in_email(other) == "ada@example.com"

    # A session of its own: signing out over there leaves this one.
    {_other, _conn} = post(other, "/sign-out")
    assert signed_in_email(browser) == "ada@example.com"

    {_again, conn} = post(Browser.new(Auth), "/one-time-token/verify", %{token: token})
    assert json(conn)["error"]["code"] == "invalid_token"
  end

  test "expired and made-up tokens don't work", %{browser: browser} do
    {_browser, user} = sign_up(browser)
    {:ok, token} = OneTimeToken.generate(Auth, user["id"])

    Repo.update_all("verifications",
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    for bad <- [token, "made-up"] do
      {_other, conn} = post(Browser.new(Auth), "/one-time-token/verify", %{token: bad})
      assert json(conn)["error"]["code"] == "invalid_token"
    end
  end

  @tag auth: ServerOnlyAuth
  test "server-made tokens, traded for a bearer token", %{browser: browser} do
    {browser, user} = sign_up(browser)
    {_browser, conn} = get(browser, "/one-time-token/generate")
    assert conn.status == 404

    {:ok, token} = OneTimeToken.generate(ServerOnlyAuth, user["id"])
    {_other, conn} = post(Browser.new(ServerOnlyAuth), "/one-time-token/verify", %{token: token})
    assert conn.resp_cookies == %{}
    session_token = json(conn)["token"]

    client = %{
      Browser.new(ServerOnlyAuth)
      | headers: [{"authorization", "Bearer " <> session_token}]
    }

    assert signed_in_email(client) == "ada@example.com"
  end
end
