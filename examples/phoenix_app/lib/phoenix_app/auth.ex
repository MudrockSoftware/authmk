defmodule PhoenixApp.Auth do
  use Authmk,
    otp_app: :phoenix_app,
    repo: PhoenixApp.Repo,
    plugins: [Authmk.Plugins.EmailPassword]

  import Swoosh.Email

  alias PhoenixApp.Mailer

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
    |> from({"PhoenixApp", "no-reply@phoenix-app.example"})
    |> subject(subject)
    |> text_body(body)
    |> Mailer.deliver()
  end
end
