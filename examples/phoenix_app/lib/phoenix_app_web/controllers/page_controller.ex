defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  def home(conn, _params) do
    providers = Map.keys(PhoenixApp.Auth.config().social_providers)
    last_used = Authmk.Plugins.LastSignInMethod.get(conn, PhoenixApp.Auth)
    render(conn, :home, providers: providers, last_used: last_used)
  end

  def account(conn, _params) do
    render(conn, :account, user: conn.assigns.current_user)
  end
end
