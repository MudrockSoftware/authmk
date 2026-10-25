defmodule PhoenixAppWeb.PageController do
  use PhoenixAppWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def account(conn, _params) do
    render(conn, :account, user: conn.assigns.current_user)
  end
end
