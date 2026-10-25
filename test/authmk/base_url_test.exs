defmodule Authmk.BaseURLTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: [allowed_hosts: ["app.example.com", "*.preview.example.com", "localhost:4000"]],
    background: :inline,
    rate_limit: [enabled: false]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.BaseURLTest.FallbackAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: [
      allowed_hosts: ["app.example.com"],
      protocol: "https",
      fallback: "https://app.example.com"
    ],
    background: :inline,
    rate_limit: [enabled: false]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.BaseURLTest do
  use Authmk.EmulationCase, async: true

  @moduletag auth: Authmk.BaseURLTest.Auth

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  defp from_host(browser, host, proto) do
    %{browser | origin: "#{proto}://#{host}", host: host, headers: [{"x-forwarded-proto", proto}]}
  end

  test "links and cookies follow the request's allowed host", %{browser: browser} do
    preview = from_host(browser, "pr-12.preview.example.com", "https")
    {preview, conn} = post(preview, "/sign-up/email", @user)

    assert conn.status == 200
    assert cookie(preview, "__Secure-authmk.session_token")

    {_preview, _conn} = post(preview, "/request-password-reset", %{email: @user.email})
    link = assert_email(:reset_password)
    assert link.url =~ "https://pr-12.preview.example.com/auth/reset-password/"

    local = from_host(browser, "localhost:4000", "http")
    {_local, _conn} = post(local, "/request-password-reset", %{email: @user.email})
    link = assert_email(:reset_password)
    assert link.url =~ "http://localhost:4000/auth/reset-password/"
  end

  test "unknown, spoofed and malformed hosts are refused", %{browser: browser} do
    for {host, headers} <- [
          {"evil.example", []},
          {"app.example.com", [{"x-forwarded-host", "evil.example"}]},
          {"app.example.com", [{"x-forwarded-host", "app.example.com/evil"}]},
          {"app.example.com", [{"x-forwarded-host", "user@app.example.com"}]}
        ] do
      {_browser, conn} = get(%{browser | host: host, headers: headers}, "/ok")

      assert json(conn)["error"]["code"] == "invalid_host",
             "expected #{inspect({host, headers})} to be refused"
    end
  end

  test "allowed hosts are trusted origins", %{browser: browser} do
    allowed = from_host(browser, "app.example.com", "https")

    {_browser, conn} =
      post(%{allowed | origin: "https://pr-3.preview.example.com"}, "/sign-up/email", @user)

    assert conn.status == 200

    {_browser, conn} = post(%{allowed | origin: "https://evil.example"}, "/sign-up/email", @user)
    assert json(conn)["error"]["code"] == "invalid_origin"
  end

  @tag auth: Authmk.BaseURLTest.FallbackAuth
  test "with a fallback, unknown hosts get the canonical URL", %{browser: browser} do
    stranger = %{browser | origin: "https://app.example.com", host: "other.example"}
    {_browser, _conn} = post(stranger, "/sign-up/email", @user)
    {_browser, _conn} = post(stranger, "/request-password-reset", %{email: @user.email})

    link = assert_email(:reset_password)
    assert link.url =~ "https://app.example.com/auth/reset-password/"
  end
end
