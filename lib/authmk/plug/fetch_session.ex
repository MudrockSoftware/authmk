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

  alias Authmk.{ConnContext, Router, Sessions}

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :auth)

  @impl true
  def call(conn, auth) do
    case ConnContext.new(conn, auth) do
      {:ok, ctx} ->
        ctx = Sessions.load(ctx, cache: true)

        ctx.conn
        |> Router.put_resp_cookies(ctx)
        |> assign_session(ctx.user, ctx.session)
        |> Plug.Conn.assign(:current_principal, ctx.private[:principal] || ctx.user)

      # A host outside base_url's allow list never gets a session.
      :invalid_host ->
        conn |> assign_session(nil, nil) |> Plug.Conn.assign(:current_principal, nil)
    end
  end

  defp assign_session(conn, user, session) do
    conn
    |> Plug.Conn.assign(:current_user, user)
    |> Plug.Conn.assign(:current_session, session)
  end
end
