defmodule Authmk.Test.Phoenix do
  @moduledoc false
  # A small Phoenix app using authmk the way an app would: the router macros,
  # FetchSession in the browser pipeline, LiveViews with Authmk.LiveView's
  # hooks, and Authmk.Components.

  defmodule Auth do
    @moduledoc false
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [github: [client_id: "github-id", client_secret: "client-secret"]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, issuer: "Test"},
        Authmk.Plugins.Organization
      ]

    # Requests run in the test process: the test receives the email.
    @impl Authmk
    def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
  end

  defmodule Layout do
    @moduledoc false
    use Phoenix.Component

    def root(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html>
        <head><Authmk.Components.passkey_script /></head>
        <body>{@inner_content}</body>
      </html>
      """
    end
  end

  defmodule SignInLive do
    @moduledoc false
    use Phoenix.LiveView
    import Authmk.Components

    def mount(params, _session, socket), do: {:ok, assign(socket, error: params["error"])}

    def render(assigns) do
      ~H"""
      <.sign_in_form redirect_to="/settings" two_factor_redirect_to="/two-factor" error={@error} />
      """
    end
  end

  defmodule SettingsLive do
    @moduledoc false
    use Phoenix.LiveView
    import Authmk.Components.Account

    alias Authmk.Plugins.Organization

    def mount(params, _session, socket) do
      user = socket.assigns.current_user
      sessions = Authmk.Sessions.list(Authmk.Context.new(Auth.config()), user.id)

      {:ok,
       assign(socket,
         error: params["error"],
         sessions: sessions,
         organizations: Organization.list_for_user(Auth, user)
       )}
    end

    def render(assigns) do
      ~H"""
      <p id="email">{@current_user.email}</p>
      <p id="principal">{@current_principal.email}</p>
      <.organization_switcher
        organizations={@organizations}
        active_organization_id={@current_session.active_organization_id}
        redirect_to="/settings"
      />
      <.account_settings
        user={@current_user}
        sessions={@sessions}
        current_session={@current_session}
        redirect_to="/settings"
        error={@error}
      />
      """
    end
  end

  defmodule HomeLive do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(assigns) do
      ~H"""
      <p id="who">{if @current_user, do: @current_user.email, else: "signed out"}</p>
      """
    end
  end

  defmodule Router do
    @moduledoc false
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Authmk.Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :put_root_layout, html: {Layout, :root}
      plug Authmk.Plug.FetchSession, auth: Auth
    end

    scope "/" do
      authmk_routes("/auth", Auth)
    end

    scope "/" do
      pipe_through(:browser)

      authmk_live_session :public, Auth do
        live("/", HomeLive)
      end

      authmk_live_session :signed_out, Auth, require: :signed_out, redirect_to: "/settings" do
        live("/sign-in", SignInLive)
      end

      authmk_live_session :signed_in, Auth, require: :user, redirect_to: "/sign-in" do
        live("/settings", SettingsLive)
      end
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :authmk

    @session_options [store: :cookie, key: "_test_key", signing_salt: "test-salt"]

    socket("/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]]
    )

    plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON
    plug Plug.Session, @session_options
    plug Router
  end
end
