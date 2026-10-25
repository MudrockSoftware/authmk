defmodule PlugApp.Auth do
  use Authmk,
    otp_app: :plug_app,
    repo: PlugApp.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.Username,
      Authmk.Plugins.Anonymous,
      {Authmk.Plugins.PhoneNumber,
       send_otp: &__MODULE__.send_phone_code/2, sign_up_on_verification: true},
      {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2},
      {Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_email_code/2},
      {Authmk.Plugins.TwoFactor, issuer: "PlugApp", send_otp: &__MODULE__.send_two_factor_code/2}
    ]

  import Swoosh.Email

  @impl Authmk
  def send_verification_email(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Verify your email", "Open this link to verify your email:\n\n#{url}")
  end

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Reset your password", "Open this link to reset your password:\n\n#{url}")
  end

  def send_two_factor_code(%{user: user, otp: code}, _ctx) do
    deliver(user.email, "Your sign-in code", "Your sign-in code is #{code}")
  end

  def send_phone_code(%{phone_number: number, code: code}, _ctx) do
    PlugApp.SMS.deliver(number, "Your PlugApp code is #{code}")
  end

  def send_magic_link(%{email: email, url: url}, _ctx) do
    deliver(email, "Your sign-in link", "Open this link to sign in:\n\n#{url}")
  end

  def send_email_code(%{email: email, otp: code}, _ctx) do
    deliver(email, "Your code", "Your code is #{code}")
  end

  defp deliver(to, subject, body) do
    new()
    |> to(to)
    |> from({"PlugApp", "no-reply@example.com"})
    |> subject(subject)
    |> text_body(body)
    |> PlugApp.Mailer.deliver()
  end
end
