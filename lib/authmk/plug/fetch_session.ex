defmodule Authmk.Plug.FetchSession do
  @moduledoc """
  Loads the signed-in session into `conn.assigns`:
  `:current_user` and `:current_session` (both `nil` when signed out), and
  `:current_principal`: the user, or what else authenticated the request
  (like a service account, see `Authmk.Plugins.ServiceAccount`).

      plug Authmk.Plug.FetchSession, auth: MyApp.Auth

  It also refreshes the session cookie when the session is due for a refresh.
  When the cookie cache is enabled, it reads from it (see `Authmk.CookieCache`).
  """

  @behaviour Plug

  alias Authmk.{BaseURL, Config, Context, Router, Sessions}

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :auth)

  @impl true
  def call(conn, auth) do
    conn = Plug.Conn.fetch_cookies(conn)
    config = Config.fetch!(auth)

    case BaseURL.resolve(config, conn) do
      {:ok, base_url} ->
        ctx = Sessions.load(%Context{config: config, conn: conn, base_url: base_url}, cache: true)

        conn
        |> Router.put_resp_cookies(ctx)
        |> assign_session(ctx.user, ctx.session)
        |> Plug.Conn.assign(:current_principal, ctx.private[:principal] || ctx.user)

      # A host outside base_url's allow list never gets a session.
      {:error, _invalid_host} ->
        conn |> assign_session(nil, nil) |> Plug.Conn.assign(:current_principal, nil)
    end
  end

  defp assign_session(conn, user, session) do
    conn
    |> Plug.Conn.assign(:current_user, user)
    |> Plug.Conn.assign(:current_session, session)
  end
end
