defmodule Authmk.Plug.RequireUser do
  @moduledoc """
  Lets through only requests from a signed-in user: not signed-out ones,
  and not other principals, like service accounts with API keys. Use after
  `Authmk.Plug.FetchSession`.

      plug Authmk.Plug.RequireUser                      # 401 JSON
      plug Authmk.Plug.RequireUser, redirect_to: "/sign-in"

  It's `Authmk.Plug.RequireAuthenticated` without `allow_principals`, named
  for what it guarantees: `conn.assigns.current_user` is set.
  """

  @behaviour Plug

  alias Authmk.Plug.RequireAuthenticated

  @impl true
  def init(opts), do: RequireAuthenticated.init(Keyword.put(opts, :allow_principals, false))

  @impl true
  def call(conn, opts), do: RequireAuthenticated.call(conn, opts)
end
