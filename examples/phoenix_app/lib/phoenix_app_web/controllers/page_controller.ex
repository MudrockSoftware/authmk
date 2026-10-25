defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  def home(conn, _params) do
    providers = Map.keys(PhoenixApp.Auth.config().social_providers)
    render(conn, :home, providers: providers)
  end

  def account(conn, _params) do
    render(conn, :account, user: conn.assigns.current_user)
  end
end
