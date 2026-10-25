defmodule PlugApp.Auth do
  use Authmk,
    otp_app: :plug_app,
    repo: PlugApp.Repo,
    plugins: [Authmk.Plugins.EmailPassword]

  import Swoosh.Email

  @impl Authmk
  def send_verification_email(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Verify your email", "Open this link to verify your email:\n\n#{url}")
  end

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Reset your password", "Open this link to reset your password:\n\n#{url}")
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
