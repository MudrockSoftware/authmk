defmodule Authmk.CaptchaTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  for provider <- [:turnstile, :recaptcha, :hcaptcha, :captchafox] do
    module = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(provider)))

    defmodule module do
      use Authmk,
        otp_app: :authmk,
        repo: Authmk.Test.Repo,
        base_url: "http://localhost:4000",
        background: :inline,
        rate_limit: [enabled: false],
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.Captcha,
           provider: provider, secret_key: "captcha-secret", site_key: "site-key"}
        ],
        advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
    end
  end

  @moduletag auth: __MODULE__.Turnstile

  @hosts %{
    turnstile: {"challenges.cloudflare.com", "/turnstile/v0/siteverify"},
    recaptcha: {"www.google.com", "/recaptcha/api/siteverify"},
    hcaptcha: {"api.hcaptcha.com", "/siteverify"},
    captchafox: {"api.captchafox.com", "/siteverify"}
  }

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  # Plays the provider: "good" solves it, anything else doesn't.
  defp stub(auth, provider, answer \\ nil) do
    test = self()
    {host, path} = @hosts[provider]

    Req.Test.stub(auth, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      send(test, {:verified, conn.host, conn.request_path, form})
      assert {conn.host, conn.request_path} == {host, path}
      Req.Test.json(conn, answer || %{"success" => form["response"] == "good"})
    end)
  end

  defp sign_up_with(auth, token) do
    browser = %{
      Browser.new(auth)
      | headers: if(token, do: [{"x-captcha-response", token}], else: [])
    }

    post(browser, "/sign-up/email", @user)
  end

  for provider <- [:turnstile, :recaptcha, :hcaptcha, :captchafox] do
    @tag auth: Module.concat(__MODULE__, Macro.camelize(Atom.to_string(provider)))
    test "#{provider}: solved, failed, missing", %{auth: auth} do
      stub(auth, unquote(provider))

      {_browser, conn} = sign_up_with(auth, "bad")
      assert json(conn)["error"]["code"] == "captcha_failed"

      {_browser, conn} = sign_up_with(auth, nil)
      assert json(conn)["error"]["code"] == "captcha_required"

      {_browser, conn} = sign_up_with(auth, "good")
      assert json(conn)["user"]["email"] == "ada@example.com"

      assert_received {:verified, _host, _path,
                       %{
                         "secret" => "captcha-secret",
                         "response" => "good",
                         "remoteip" => "127.0.0.1",
                         "sitekey" => "site-key"
                       }}
    end
  end

  @tag auth: __MODULE__.Recaptcha
  test "reCAPTCHA v3 scores below the threshold are refused", %{auth: auth} do
    stub(auth, :recaptcha, %{"success" => true, "score" => 0.3})
    {_browser, conn} = sign_up_with(auth, "good")
    assert json(conn)["error"]["code"] == "captcha_failed"

    stub(auth, :recaptcha, %{"success" => true, "score" => 0.9})
    {_browser, conn} = sign_up_with(auth, "good")
    assert json(conn)["user"]
  end

  test "an unreachable provider lets nobody through", %{auth: auth} do
    Req.Test.stub(auth, &Plug.Conn.send_resp(&1, 500, "down"))
    {_browser, conn} = sign_up_with(auth, "good")
    assert conn.status == 503
    assert json(conn)["error"]["code"] == "captcha_unavailable"
    assert Repo.aggregate("users", :count) == 0
  end

  test "endpoints that aren't listed need no captcha", %{auth: auth} do
    stub(auth, :turnstile)
    {browser, _conn} = sign_up_with(auth, "good")
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]
  end
end
