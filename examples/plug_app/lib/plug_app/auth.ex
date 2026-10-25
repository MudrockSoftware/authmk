defmodule PlugApp.Auth do
  use Authmk,
    otp_app: :plug_app,
    repo: PlugApp.Repo,
    plugins: [Authmk.Plugins.EmailPassword]

  alias PlugApp.Mailer

  @impl Authmk
  def send_verification_email(%{user: user, url: url}, _ctx) do
    Mailer.deliver_link(
      user.email,
      "Verify your email",
      "Open this link to verify your email:",
      url
    )
  end

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx) do
    Mailer.deliver_link(
      user.email,
      "Reset your password",
      "Open this link to reset your password:",
      url
    )
  end
end
