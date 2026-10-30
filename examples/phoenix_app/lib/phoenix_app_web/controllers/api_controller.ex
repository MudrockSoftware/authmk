defmodule PhoenixAppWeb.ApiController do
  use PhoenixAppWeb, :controller

  def mcp(conn, _params), do: json(conn, %{tools: [], user: conn.assigns.current_user.email})

  # For apps holding a user's access token with the profile scope.
  # A user's token, or a service account's (client credentials): both have a name.
  def profile(conn, _params), do: json(conn, %{name: conn.assigns.current_principal.name})

  # Who called: a signed-in user, or a service account with its API key.
  def whoami(conn, _params) do
    case conn.assigns do
      %{current_user: %{} = user} ->
        json(conn, %{type: "user", name: user.name})

      %{current_principal: service_account} ->
        json(conn, %{type: "service_account", name: service_account.name})
    end
  end
end
