defmodule PlugApp.Mailer do
  use Swoosh.Mailer, otp_app: :plug_app

  import Swoosh.Email

  @doc "Sends a one-link email."
  def deliver_link(to, subject, text, url) do
    new()
    |> to(to)
    |> from({"PlugApp", "no-reply@plug-app.example"})
    |> subject(subject)
    |> text_body("#{text}\n\n#{url}\n")
    |> deliver()
  end
end
