defmodule PhoenixAppWeb.SettingsLive do
  @moduledoc "Account settings for the signed-in user, with authmk's components."
  use PhoenixAppWeb, :live_view

  import Authmk.Components, only: [passkey_button: 1]
  import Authmk.Components.Account

  alias Authmk.Plugins.Organization

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    ctx = Authmk.Context.new(PhoenixApp.Auth.config())

    {:ok,
     assign(socket,
       error: params["error"],
       sessions: Authmk.Sessions.list(ctx, user.id),
       organizations: Organization.list_for_user(PhoenixApp.Auth, user)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Settings</h1>
      <.organization_switcher
        :if={@organizations != []}
        organizations={@organizations}
        active_organization_id={@current_session.active_organization_id}
        redirect_to={~p"/settings"}
      />
      <.account_settings
        user={@current_user}
        sessions={@sessions}
        current_session={@current_session}
        redirect_to={~p"/settings"}
        error={@error}
        class="mt-4 flex flex-col gap-6"
      />
      <.passkey_button
        action={:register}
        redirect_to={~p"/settings"}
        error_redirect_to={~p"/settings"}
      />
    </Layouts.app>
    """
  end
end
