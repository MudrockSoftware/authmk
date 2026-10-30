defmodule PhoenixAppWeb.AuthErrorHTML do
  @moduledoc """
  The app's own page for sign-in errors in redirect flows, instead of
  authmk's (`errors: [page: ...]` in config). authmk calls `page/2` with
  the error's `code` and `message`, `home`, and the branding edited in the
  dashboard (`app_name`, `logo_url`, `primary_color`).
  """
  use PhoenixAppWeb, :html

  def page(data, _ctx) do
    data |> error_page() |> Phoenix.HTML.Safe.to_iodata()
  end

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Sign-in problem · {@app_name}</title>
      </head>
      <body style="font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto">
        <img :if={@logo_url} src={@logo_url} alt={@app_name} height="40" />
        <h1>We couldn't sign you in</h1>
        <p>{@message}</p>
        <p>Error code: <code>{@code}</code></p>
        <a href={@home} style={@primary_color && "color: #{@primary_color}"}>
          Back to {@app_name}
        </a>
      </body>
    </html>
    """
  end
end
