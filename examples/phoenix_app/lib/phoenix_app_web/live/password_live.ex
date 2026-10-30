defmodule PhoenixAppWeb.PasswordLive do
  @moduledoc "Forgot and reset password, with authmk's components."
  use PhoenixAppWeb, :live_view

  import Authmk.Components

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign(socket, error: params["error"], token: params["token"], sent: params["sent"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <p :if={@sent}>If that email has an account, a reset link is on its way.</p>
      <.reset_password_form :if={@token} token={@token} redirect_to={~p"/sign-in"} error={@error} />
      <.forgot_password_form
        :if={!@token && !@sent}
        redirect_to={~p"/forgot-password?sent=true"}
        reset_url={~p"/reset-password"}
        error={@error}
      />
    </Layouts.app>
    """
  end
end
