defmodule Authmk.MessagingTest do
  use Authmk.EmulationCase, async: true

  import Swoosh.TestAssertions

  alias Authmk.Test.Browser

  defmodule Mailer do
    use Swoosh.Mailer, otp_app: :authmk, adapter: Swoosh.Adapters.Test
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      app_name: "Acme <Beta>",
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2},
        {Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_email_code/2},
        {Authmk.Plugins.PhoneNumber, send_otp: &__MODULE__.send_phone_code/2}
      ]

    @from {"Acme", "no-reply@acme.example"}

    @impl Authmk
    def send_reset_password(data, ctx),
      do: data |> Authmk.Emails.reset_password(ctx, from: @from) |> Mailer.deliver()

    def send_magic_link(data, ctx),
      do: data |> Authmk.Emails.magic_link(ctx, from: @from) |> Mailer.deliver()

    def send_email_code(data, ctx),
      do: data |> Authmk.Emails.otp(ctx, from: @from) |> Mailer.deliver()

    def send_phone_code(message, ctx), do: Authmk.SMS.send_otp(Authmk.SMS.Test, message, ctx)
  end

  @moduletag auth: Auth

  test "password reset, magic link and code emails", %{browser: browser} do
    {_browser, _user} = sign_up(browser)

    {_browser, _conn} =
      post(Browser.new(Auth), "/request-password-reset", %{
        email: "ada@example.com",
        redirect_to: "/reset"
      })

    assert_email_sent(fn email ->
      assert email.subject == "Reset your password"
      assert email.to == [{"", "ada@example.com"}]
      assert email.from == {"Acme", "no-reply@acme.example"}
      assert email.text_body =~ "http://localhost:4000/auth/reset-password/"
      # The app name is escaped in HTML, as everything is.
      assert email.html_body =~ "Acme &lt;Beta&gt;"
      refute email.html_body =~ "<Beta>"
      true
    end)

    {_browser, _conn} =
      post(Browser.new(Auth), "/sign-in/magic-link", %{email: "bob@example.com"})

    assert_email_sent(subject: "Your sign-in link", to: [{"", "bob@example.com"}])

    {_browser, _conn} =
      post(Browser.new(Auth), "/email-otp/send-verification-otp", %{
        email: "ada@example.com",
        type: "sign-in"
      })

    assert_email_sent(fn email ->
      assert email.subject == "Your Acme <Beta> code"
      assert [_code] = Regex.run(~r/\b\d{6}\b/, email.text_body)
    end)
  end

  test "phone codes through an SMS sender", %{browser: browser} do
    {_browser, _conn} = post(browser, "/phone-number/send-otp", %{phone_number: "+15551234567"})
    assert_receive {:sms, "+15551234567", body}
    assert body =~ ~r/^\d{6} is your Acme <Beta> code\. Don't share it\.$/
  end

  test "every template, with what users control escaped" do
    ctx = Authmk.Context.new(Auth.config())
    user = %{email: "ada@example.com"}
    url = "https://acme.example/x?a=1&b=<2>"

    for {email, subject} <- [
          {Authmk.Emails.verification(%{user: user, url: url}, ctx, from: "a@acme.example"),
           "Verify your email"},
          {Authmk.Emails.change_email(%{new_email: "new@example.com", url: url}, ctx,
             from: "a@acme.example"
           ), "Confirm your new email"},
          {Authmk.Emails.delete_account(%{user: user, url: url}, ctx, from: "a@acme.example"),
           "Confirm deleting your account"},
          {Authmk.Emails.otp(%{user: user, otp: "123456"}, ctx,
             from: "a@acme.example",
             app_name: "Acme"
           ), "Your Acme code"}
        ] do
      assert email.subject == subject
      refute email.html_body =~ "<2>"
    end

    organization = %{name: "<script>Org</script>"}
    inviter = %{name: "Bob", email: "bob@example.com"}

    invite =
      Authmk.Emails.invitation(
        %{id: "inv-1", email: "eve@example.com", organization: organization, inviter: inviter},
        ctx,
        from: "a@acme.example"
      )

    assert invite.text_body =~ "invited by Bob"
    refute invite.html_body =~ "<script>"

    with_link =
      Authmk.Emails.invitation(
        %{id: "inv-1", email: "eve@example.com", organization: organization},
        ctx,
        from: "a@acme.example",
        accept_url: url
      )

    assert with_link.text_body =~ "Accept invitation: " <> url
  end
end
