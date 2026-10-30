defmodule Authmk.BackgroundTest.Auth do
  # The production default: emails go out from a supervised task.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    rate_limit: [enabled: false]

  @impl Authmk
  def send_reset_password(link, _ctx) do
    send(:authmk_background_test, {:email, :reset_password, link, self()})
  end
end

defmodule Authmk.BackgroundTest.SilentAuth do
  # Implements no email callbacks.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.BackgroundTest do
  use Authmk.EmulationCase, async: true

  import ExUnit.CaptureLog

  @moduletag auth: Authmk.BackgroundTest.Auth

  test "emails are sent from a background task, not the request process", %{browser: browser} do
    Process.register(self(), :authmk_background_test)
    {_browser, _user} = sign_up(browser)

    {_browser, conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
    assert json(conn) == %{"status" => true}

    assert_receive {:email, :reset_password, link, sender}, 1000
    assert link.url =~ "/auth/reset-password/"
    assert sender != self()
  end

  @tag auth: Authmk.BackgroundTest.SilentAuth
  test "a missing email callback logs a warning instead of failing", %{browser: browser} do
    {_browser, _user} = sign_up(browser)

    log =
      capture_log(fn ->
        {_browser, conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
        assert json(conn) == %{"status" => true}
      end)

    assert log =~ "doesn't implement send_reset_password/2, so no email was sent"
  end

  @tag auth: Authmk.BackgroundTest.SilentAuth
  test "deliveries are remembered for health checks: names and times, never contents", %{
    browser: browser
  } do
    capture_log(fn ->
      {_browser, _user} = sign_up(browser)
      post(browser, "/request-password-reset", %{email: "ada@example.com"})
    end)

    assert [%{name: "send_reset_password", channel: :email, not_implemented: true} = delivery] =
             Authmk.Deliveries.list(Authmk.BackgroundTest.SilentAuth)

    assert delivery.last_failed_at
    refute inspect(delivery) =~ "ada@example.com"
  end
end
