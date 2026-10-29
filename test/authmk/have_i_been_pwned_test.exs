defmodule Authmk.HaveIBeenPwnedTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.HaveIBeenPwned
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.HaveIBeenPwned],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  defmodule OpenAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.HaveIBeenPwned, fail_open: true, message: "Pick another"}
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  @breached "password123"

  # Plays the API: the breached password's suffix with a count, a padding
  # line with count 0 for the safe one.
  defp stub(auth) do
    test = self()

    [breached, safe] =
      for password <- [@breached, "correct horse"],
          do: :sha |> :crypto.hash(password) |> Base.encode16()

    Req.Test.stub(auth, fn conn ->
      send(test, {:range, conn.request_path, Plug.Conn.get_req_header(conn, "add-padding")})

      body =
        "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n" <>
          String.slice(breached, 5..-1//1) <> ":24230\r\n" <> String.slice(safe, 5..-1//1) <> ":0"

      Plug.Conn.send_resp(conn, 200, body)
    end)
  end

  test "breached passwords are refused, and only a hash prefix is sent", %{browser: browser} do
    stub(Auth)

    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: @breached,
        name: "Ada"
      })

    assert json(conn)["error"]["code"] == "password_compromised"
    assert Repo.aggregate("users", :count) == 0

    assert_received {:range, "/range/" <> prefix, ["true"]}
    assert String.length(prefix) == 5

    # A padding line (count 0) isn't a breach.
    {browser, _user} = sign_up(browser)

    {_browser, conn} =
      post(browser, "/change-password", %{
        current_password: "correct horse",
        new_password: @breached
      })

    assert json(conn)["error"]["code"] == "password_compromised"
  end

  test "custom flows check with check/2", %{browser: _browser} do
    stub(Auth)
    assert {:error, %{code: :password_compromised}} = HaveIBeenPwned.check(Auth, @breached)
    assert :ok = HaveIBeenPwned.check(Auth, "correct horse")
  end

  test "when the service is down, passwords are refused", %{browser: browser} do
    Req.Test.stub(Auth, &Plug.Conn.send_resp(&1, 503, "down"))

    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse",
        name: "Ada"
      })

    assert conn.status == 503
    assert json(conn)["error"]["code"] == "password_check_unavailable"
  end

  @tag auth: OpenAuth
  test "fail_open lets them through instead, and the message is the app's", %{browser: _browser} do
    Req.Test.stub(OpenAuth, &Plug.Conn.send_resp(&1, 503, "down"))

    {_browser, conn} =
      post(Browser.new(OpenAuth), "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json(conn)["user"]

    stub(OpenAuth)
    assert {:error, %{message: "Pick another"}} = HaveIBeenPwned.check(OpenAuth, @breached)
  end
end
