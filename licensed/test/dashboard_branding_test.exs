defmodule Authmk.DashboardBrandingTest do
  # Branding edited in the dashboard shows on authmk's error page, in its
  # emails and on the dashboard itself; the logo is served from the app.
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers
  import Swoosh.TestAssertions

  alias Authmk.Test.Browser
  alias Authmk.Testing

  defmodule Mailer do
    use Swoosh.Mailer, otp_app: :authmk, adapter: Swoosh.Adapters.Test
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      app_name: "Configured",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        Authmk.Plugins.AuditLog,
        Authmk.Dashboard.Branding
      ]

    @impl Authmk
    def send_reset_password(data, ctx),
      do:
        data
        |> Authmk.Emails.reset_password(ctx, from: "no-reply@acme.example")
        |> Mailer.deliver()
  end

  @moduletag auth: Auth

  # The smallest PNG there is: one transparent pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", role: "admin")}
  end

  defp page_data(html) do
    [_, json] =
      Regex.run(~r{<script type="application/json" id="authmk-page">(.*?)</script>}, html)

    JSON.decode!(json)
  end

  test "name, colour and logo, on the error page, in emails and the dashboard", %{
    browser: browser,
    admin: admin
  } do
    {200, %{"branding" => branding}} = get_json(Auth, "branding", admin)
    assert branding == %{"app_name" => nil, "primary_color" => nil, "logo_url" => nil}

    assert {200, %{"branding" => saved}} =
             post_json(Auth, "branding", admin, %{
               app_name: "Acme",
               primary_color: "#1D4ED8",
               logo: %{type: "image/png", data: Base.encode64(@png)}
             })

    assert %{"app_name" => "Acme", "primary_color" => "#1d4ed8", "logo_url" => logo_url} = saved
    assert logo_url =~ ~r{^http://localhost:4000/auth/branding/logo\?v=}

    # The dashboard shows it too.
    {200, me} = get_json(Auth, "me", admin)
    assert me["branding"]["app_name"] == "Acme"

    # The logo, from the app, so nothing in it runs.
    {_browser, conn} = Browser.get(browser, "/branding/logo")
    assert conn.status == 200
    assert conn.resp_body == @png
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
    assert [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"

    {_browser, conn} = Browser.get(browser, "/error", %{error: "invalid_token"})
    data = page_data(conn.resp_body)
    assert %{"app_name" => "Acme", "primary_color" => "#1d4ed8"} = data
    assert data["logo_url"] == logo_url

    {_browser, _user} = sign_up(browser)

    Browser.post(Browser.new(Auth), "/request-password-reset", %{
      email: "ada@example.com",
      redirect_to: "/reset"
    })

    assert_email_sent(fn email ->
      assert email.html_body =~ "background:#1d4ed8;color:#ffffff"
      assert email.html_body =~ ~s(<img src="#{String.replace(logo_url, "&", "&amp;")}")
      assert email.subject == "Reset your password"
      assert email.html_body =~ "Acme"
      true
    end)

    assert "dashboard.branding.updated" in Enum.map(dashboard_events(Auth), & &1.event)

    # Back to the config's look.
    assert {200, _} =
             post_json(Auth, "branding", admin, %{app_name: "", primary_color: nil, logo: nil})

    {_browser, conn} = Browser.get(Browser.new(Auth), "/error", %{error: "invalid_token"})
    assert %{"app_name" => "Configured", "logo_url" => nil} = page_data(conn.resp_body)
    {_browser, conn} = Browser.get(Browser.new(Auth), "/branding/logo")
    assert conn.status == 404
  end

  test "what isn't a colour, a name or the image it claims is refused", %{admin: admin} do
    for change <- [
          %{primary_color: "red"},
          %{primary_color: "#1d4ed8; background: url(x)"},
          %{app_name: String.duplicate("a", 101)},
          %{logo: %{type: "image/png", data: Base.encode64("<svg onload=alert(1)>")}},
          %{logo: %{type: "text/html", data: Base.encode64("<p>")}},
          %{logo: %{type: "image/svg+xml", data: "not base64!"}},
          %{logo: %{type: "image/png", data: Base.encode64(:binary.copy(@png, 5000))}},
          %{favicon: "x"}
        ] do
      assert {400, %{"error" => %{"code" => "invalid_branding"}}} =
               post_json(Auth, "branding", admin, change)
    end

    assert {200, _} =
             post_json(Auth, "branding", admin, %{
               logo: %{type: "image/svg+xml", data: Base.encode64(~s(<svg xmlns="x"></svg>))}
             })
  end

  test "changing it needs its Admin permission" do
    user = Testing.create_user(Auth, email: "ada@example.com", role: "user")
    assert {403, _} = post_json(Auth, "branding", user, %{app_name: "Mine"})
  end
end
