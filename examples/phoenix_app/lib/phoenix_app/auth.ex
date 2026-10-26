defmodule PhoenixApp.Auth do
  use Authmk,
    otp_app: :phoenix_app,
    repo: PhoenixApp.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.Username,
      Authmk.Plugins.Anonymous,
      {Authmk.Plugins.PhoneNumber,
       send_otp: &__MODULE__.send_phone_code/2, sign_up_on_verification: true},
      {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2},
      {Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_email_code/2},
      Authmk.Plugins.Passkey,
      Authmk.Plugins.OneTap,
      Authmk.Plugins.SIWE,
      Authmk.Plugins.Admin,
      {Authmk.Plugins.Organization, send_invitation_email: &__MODULE__.send_invitation/2},
      {Authmk.Plugins.APIKey, enable_sessions: true},
      Authmk.Plugins.ServiceAccount,
      {Authmk.Plugins.TwoFactor,
       issuer: "PhoenixApp", send_otp: &__MODULE__.send_two_factor_code/2}
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
    PhoenixApp.SMS.deliver(number, "Your PhoenixApp code is #{code}")
  end

  def send_magic_link(%{email: email, url: url}, _ctx) do
    deliver(email, "Your sign-in link", "Open this link to sign in:\n\n#{url}")
  end

  def send_email_code(%{email: email, otp: code}, _ctx) do
    deliver(email, "Your code", "Your code is #{code}")
  end

  def send_invitation(%{id: id, email: email, organization: organization}, _ctx) do
    deliver(
      email,
      "Join #{organization.name}",
      "You're invited to #{organization.name}. Your invitation id is #{id}."
    )
  end

  defp deliver(to, subject, body) do
    new()
    |> to(to)
    |> from({"PhoenixApp", "no-reply@example.com"})
    |> subject(subject)
    |> text_body(body)
    |> PhoenixApp.Mailer.deliver()
  end
end
