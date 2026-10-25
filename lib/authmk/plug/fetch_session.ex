defmodule Authmk.Plug.FetchSession do
  @moduledoc """
  Loads the signed-in session into `conn.assigns`:
  `:current_user` and `:current_session` (both `nil` when signed out).

      plug Authmk.Plug.FetchSession, auth: MyApp.Auth

  It also refreshes the session cookie when the session is due for a refresh.
  """

  @behaviour Plug

  alias Authmk.{Config, Context, Router, Sessions}

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :auth)

  @impl true
  def call(conn, auth) do
    conn = Plug.Conn.fetch_cookies(conn)
    ctx = Sessions.load(%Context{config: Config.fetch!(auth), conn: conn})

    conn
    |> Router.put_resp_cookies(ctx)
    |> Plug.Conn.assign(:current_user, ctx.user)
    |> Plug.Conn.assign(:current_session, ctx.session)
  end
end
