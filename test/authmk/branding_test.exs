defmodule Authmk.BrandingTest.Plugin do
  @moduledoc false
  # Brands the app with its `branding:` option, or with what a test puts in
  # `ctx.private.branding`. `:raise` and `:exit` fail the way a broken
  # plugin would.
  use Authmk.Plugin

  alias Authmk.Context

  @impl true
  def branding(ctx) do
    branding =
      case Map.fetch(ctx.private, :branding) do
        {:ok, branding} -> branding
        :error -> Context.plugin_opts(ctx, __MODULE__)[:branding]
      end

    case branding do
      :raise -> raise "branding store unavailable: secret-ish detail"
      :exit -> exit(:timeout)
      branding -> branding
    end
  end
end

defmodule Authmk.BrandingTest do
  use Authmk.EmulationCase, async: true

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Authmk.{Branding, Context}
  alias Authmk.BrandingTest.Plugin

  defmodule Mailer do
    use Swoosh.Mailer, otp_app: :authmk, adapter: Swoosh.Adapters.Test
  end

  defmodule Templates do
    @moduledoc false
    # The app's own error page template.
    def error_page(data, _ctx) do
      [
        "<!doctype html><title>Oops</title><p id=\"custom\">",
        Plug.HTML.html_escape(data.code),
        " at ",
        Plug.HTML.html_escape(data.app_name),
        "</p><p>",
        Enum.map_join(
          [data.logo_url, data.primary_color, data.primary_content_color],
          " ",
          &"#{&1}"
        ),
        "</p>"
      ]
    end

    def broken_error_page(_data, _ctx), do: raise("template bug: secret-ish detail")
  end

  defmodule Branded do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      app_name: "Plain",
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Plugin,
         branding: %{
           app_name: "  Acme <Labs>  ",
           logo_url: "/brand/logo.svg?v=1&size=2",
           primary_color: "#FFCC00"
         }}
      ]

    @impl Authmk
    def send_reset_password(data, ctx),
      do:
        data
        |> Authmk.Emails.reset_password(ctx, from: "no-reply@acme.example")
        |> Mailer.deliver()
  end

  defmodule Hostile do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      app_name: "Plain",
      plugins: [
        {Plugin,
         branding: %{
           app_name: "   ",
           logo_url: "javascript:alert(1)",
           primary_color: "red; background:url(https://evil.example)"
         }}
      ]
  end

  defmodule Broken do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      app_name: "Plain",
      plugins: [Authmk.Plugins.EmailPassword, {Plugin, branding: :raise}]

    @impl Authmk
    def send_reset_password(data, ctx),
      do:
        data
        |> Authmk.Emails.reset_password(ctx, from: "no-reply@acme.example")
        |> Mailer.deliver()
  end

  defmodule CustomPage do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      errors: [page: {Templates, :error_page}],
      plugins: [
        {Plugin,
         branding: %{
           app_name: "Acme",
           logo_url: "https://cdn.example/logo.png",
           primary_color: "#1a1a2e"
         }}
      ]
  end

  defmodule BrokenPage do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      errors: [page: {Templates, :broken_error_page}]
  end

  @moduletag auth: Branded

  describe "the error page" do
    test "carries the plugin's branding, checked and normalized", %{browser: browser} do
      {_browser, conn} = get(browser, "/error", %{error: "invalid_token"})

      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]

      assert %{
               "name" => "error",
               "code" => "invalid_token",
               "app_name" => "Acme <Labs>",
               "logo_url" => "/brand/logo.svg?v=1&size=2",
               "primary_color" => "#ffcc00",
               "primary_content_color" => "#000000"
             } = page_data(conn)

      # Still only escaped JSON in the HTML.
      refute conn.resp_body =~ "Acme <Labs>"
    end

    @tag auth: Hostile
    test "drops invalid values and keeps the defaults", %{browser: browser} do
      {_browser, conn} = get(browser, "/error", %{error: "invalid_token"})

      assert %{
               "app_name" => "Plain",
               "logo_url" => nil,
               "primary_color" => nil,
               "primary_content_color" => nil
             } = page_data(conn)

      refute conn.resp_body =~ "javascript:"
      refute conn.resp_body =~ "evil.example"
    end

    @tag auth: Broken
    test "a plugin that raises leaves the page working, with the defaults", %{browser: browser} do
      log =
        capture_log(fn ->
          {_browser, conn} = get(browser, "/error", %{error: "invalid_token"})

          assert conn.status == 400
          assert %{"app_name" => "Plain", "primary_color" => nil} = page_data(conn)
        end)

      assert log =~ "branding/1 failed (RuntimeError)"
      refute log =~ "secret-ish"
    end

    @tag auth: CustomPage
    test "the app's own template, with the same data", %{browser: browser} do
      {_browser, conn} = get(browser, "/error", %{error: "<script>x</script>"})

      assert conn.status == 400
      assert ["text/html" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      assert conn.resp_body =~
               ~s(<p id="custom">&lt;script&gt;x&lt;/script&gt; at Acme</p>)

      # A logo on another origin can't show on authmk's pages: the page data
      # leaves it out, for every template.
      assert conn.resp_body =~ "<p> #1a1a2e #ffffff</p>"
      refute conn.resp_body =~ "authmk-page"
    end

    @tag auth: BrokenPage
    test "a template that raises falls back to authmk's page", %{browser: browser} do
      log =
        capture_log(fn ->
          {_browser, conn} = get(browser, "/error", %{error: "invalid_token"})

          assert conn.status == 400
          assert %{"code" => "invalid_token", "app_name" => "authmk"} = page_data(conn)
          refute conn.resp_body =~ "template bug"
        end)

      assert log =~ "Templates.broken_error_page/2 failed (RuntimeError)"
      refute log =~ "secret-ish"
    end
  end

  describe "emails" do
    test "carry the logo, colour and name, escaped", %{browser: browser} do
      {_browser, _user} = sign_up(browser)

      {_browser, _conn} =
        post(browser, "/request-password-reset", %{email: "ada@example.com", redirect_to: "/r"})

      assert_email_sent(fn email ->
        html = email.html_body

        # A logo path, made absolute against the base URL.
        assert html =~
                 ~s(<img src="http://localhost:4000/brand/logo.svg?v=1&amp;size=2" alt="Acme &lt;Labs&gt;")

        assert html =~ "background:#ffcc00;color:#000000"
        assert html =~ "<h2 style=\"font-size:18px\">Acme &lt;Labs&gt;</h2>"
        refute html =~ "<Labs>"
        true
      end)
    end

    test "an explicit app name wins; a logo path needs a base URL" do
      ctx = Context.new(Branded.config())
      email = otp_email(ctx, app_name: "Override")

      assert email.subject == "Your Override code"
      assert email.html_body =~ "Override"
      refute email.html_body =~ "<img"

      ctx = Context.put_private(ctx, :branding, %{logo_url: "https://cdn.example/logo.png"})

      assert otp_email(ctx, []).html_body =~
               ~s(<img src="https://cdn.example/logo.png" alt="Plain")
    end

    @tag auth: Broken
    test "a plugin that raises leaves emails working, with the defaults", %{browser: browser} do
      log =
        capture_log(fn ->
          {_browser, _user} = sign_up(browser)

          {_browser, _conn} =
            post(browser, "/request-password-reset", %{
              email: "ada@example.com",
              redirect_to: "/r"
            })

          assert_email_sent(fn email ->
            assert email.html_body =~ "Plain"
            assert email.html_body =~ "background:#111;color:#fff"
            refute email.html_body =~ "<img"
            true
          end)
        end)

      assert log =~ "branding/1 failed"
    end
  end

  describe "Authmk.Branding.get/1" do
    test "keeps only valid values" do
      for {given, expected} <- [
            {nil, %{app_name: "Plain", logo_url: nil, primary_color: nil}},
            {%{}, %{app_name: "Plain", logo_url: nil, primary_color: nil}},
            {%{app_name: "  Acme  "}, %{app_name: "Acme"}},
            {%{app_name: String.duplicate("a", 101)}, %{app_name: "Plain"}},
            {%{app_name: "Acme\r\nBcc: x"}, %{app_name: "Plain"}},
            {%{app_name: <<0xFF>>}, %{app_name: "Plain"}},
            {%{app_name: :acme}, %{app_name: "Plain"}},
            {%{primary_color: "#AbCdEf"}, %{primary_color: "#abcdef"}},
            {%{primary_color: "#abc"}, %{primary_color: nil}},
            {%{primary_color: "#abcdef\n"}, %{primary_color: nil}},
            {%{primary_color: "blue"}, %{primary_color: nil}},
            {%{logo_url: "https://cdn.example/logo.png"},
             %{logo_url: "https://cdn.example/logo.png"}},
            {%{logo_url: "http://localhost:4000/logo.png"},
             %{logo_url: "http://localhost:4000/logo.png"}},
            {%{logo_url: "/logo.png"}, %{logo_url: "/logo.png"}},
            {%{logo_url: "http://cdn.example/logo.png"}, %{logo_url: nil}},
            {%{logo_url: "//evil.example/logo.png"}, %{logo_url: nil}},
            {%{logo_url: "/\\evil.example/logo.png"}, %{logo_url: nil}},
            {%{logo_url: "javascript:alert(1)"}, %{logo_url: nil}},
            {%{logo_url: "data:image/svg+xml,<svg/>"}, %{logo_url: nil}},
            {%{logo_url: "https://user:pass@cdn.example/logo.png"}, %{logo_url: nil}},
            {%{logo_url: "https://cdn.example/logo.png\" onerror=\"x"}, %{logo_url: nil}},
            {%{logo_url: "logo.png"}, %{logo_url: nil}}
          ] do
        branding = branding_with(given)

        for {key, value} <- expected do
          assert Map.fetch!(branding, key) == value, "#{inspect(given)}: #{key}"
        end
      end
    end

    test "text on the primary colour is black or white, whichever reads better" do
      for {color, content} <- [
            {"#000000", "#ffffff"},
            {"#6e4a7e", "#ffffff"},
            {"#0b5fff", "#ffffff"},
            {"#ffffff", "#000000"},
            {"#ffcc00", "#000000"},
            {"#7fb2f0", "#000000"}
          ] do
        assert branding_with(%{primary_color: color}).primary_content_color == content, color
      end
    end

    test "a plugin that exits falls back to the defaults" do
      log =
        capture_log(fn ->
          assert %{app_name: "Plain", logo_url: nil} = branding_with(:exit)
        end)

      assert log =~ "branding/1 failed (exit)"
    end

    test "which logos authmk's pages and emails can show" do
      ctx = %{Context.new(Branded.config()) | base_url: "http://localhost:4000/app"}

      for {logo, page, email} <- [
            {"/logo.png", "/logo.png", "http://localhost:4000/logo.png"},
            {"http://localhost:4000/a.png", "http://localhost:4000/a.png",
             "http://localhost:4000/a.png"},
            {"https://cdn.example/a.png", nil, "https://cdn.example/a.png"}
          ] do
        branding = Branding.get(Context.put_private(ctx, :branding, %{logo_url: logo}))
        assert Branding.page_logo_url(branding, ctx) == page
        assert Branding.email_logo_url(branding, ctx) == email
      end
    end
  end

  defp branding_with(branding) do
    Branded.config()
    |> Context.new()
    |> Context.put_private(:branding, branding)
    |> Branding.get()
  end

  defp otp_email(ctx, opts) do
    Authmk.Emails.otp(
      %{email: "ada@example.com", otp: "123456"},
      ctx,
      [from: "a@acme.example"] ++ opts
    )
  end

  defp page_data(conn) do
    [data] =
      Regex.run(
        ~r{<script type="application/json" id="authmk-page">(.*?)</script>}s,
        conn.resp_body,
        capture: :all_but_first
      )

    JSON.decode!(data)
  end
end
