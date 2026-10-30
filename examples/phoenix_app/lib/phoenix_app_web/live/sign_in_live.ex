defmodule PhoenixAppWeb.SignInLive do
  @moduledoc "Sign in with authmk's components: a password form and a passkey."
  use PhoenixAppWeb, :live_view

  import Authmk.Components

  @impl true
  def mount(params, _session, socket), do: {:ok, assign(socket, error: params["error"])}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Sign in</h1>
      <.sign_in_form
        redirect_to={~p"/settings"}
        error_redirect_to={~p"/sign-in"}
        error={@error}
        class="mt-4 flex flex-col gap-3"
      />
      <.passkey_button
        redirect_to={~p"/settings"}
        error_redirect_to={~p"/sign-in"}
        class="btn mt-3 w-full"
      />
      <p class="mt-4"><.link navigate={~p"/forgot-password"}>Forgot your password?</.link></p>
    </Layouts.app>
    """
  end
end
