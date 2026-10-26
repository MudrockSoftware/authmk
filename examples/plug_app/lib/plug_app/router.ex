defmodule PlugApp.Router do
  @moduledoc """
  A plain Plug app (no Phoenix) that uses authmk.
  """

  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON
  plug :dispatch

  forward "/auth", to: PlugApp.Auth

  get "/" do
    send_resp(conn, 200, "ok")
  end

  # Only for signed-in users.
  get "/me" do
    conn =
      conn
      |> Authmk.Plug.FetchSession.call(PlugApp.Auth)
      |> Authmk.Plug.RequireAuthenticated.call(Authmk.Plug.RequireAuthenticated.init([]))

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{email: user.email, name: user.name}))
    end
  end

  # For programs too: a service account's API key gets in.
  get "/whoami" do
    conn =
      conn
      |> Authmk.Plug.FetchSession.call(PlugApp.Auth)
      |> Authmk.Plug.RequireAuthenticated.call(
        Authmk.Plug.RequireAuthenticated.init(allow_principals: true)
      )

    if conn.halted do
      conn
    else
      body =
        case conn.assigns do
          %{current_user: %{} = user} ->
            %{type: "user", name: user.name}

          %{current_principal: service_account} ->
            %{type: "service_account", name: service_account.name}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
