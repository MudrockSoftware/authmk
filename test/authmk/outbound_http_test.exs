defmodule Authmk.OutboundHTTPTest do
  # Outbound requests never follow redirects, even when the app's
  # http_options ask for them: a redirect can't send authmk to an internal
  # address (server-side request forgery).
  use Authmk.EmulationCase, async: true

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}, redirect: true]],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.HaveIBeenPwned]
  end

  @moduletag auth: Auth

  test "a redirect to an internal address isn't followed", %{browser: browser} do
    test = self()

    Req.Test.stub(Auth, fn conn ->
      send(test, {:requested, conn.host, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.send_resp(302, "")
    end)

    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse battery",
        name: "Ada"
      })

    # The check couldn't be done, so the password isn't accepted (fail closed).
    assert conn.status == 503
    assert json(conn)["error"]["code"] == "password_check_unavailable"
    assert_received {:requested, "api.pwnedpasswords.com", "/range/" <> _}
    refute_received {:requested, "169.254.169.254", _path}
  end
end
