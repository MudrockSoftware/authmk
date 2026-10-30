defmodule Authmk.Plug.RequireAuthenticated do
  @moduledoc """
  Stops requests without a signed-in user. Use after `Authmk.Plug.FetchSession`.

      plug Authmk.Plug.RequireAuthenticated                      # 401 JSON
      plug Authmk.Plug.RequireAuthenticated, redirect_to: "/sign-in"
      plug Authmk.Plug.RequireAuthenticated, allow_principals: true

  With `allow_principals: true`, other principals (service accounts) pass
  too; check `conn.assigns.current_principal` to see which.
  """

  @behaviour Plug

  alias Authmk.Error
  alias Authmk.Plug.Refusal

  @impl true
  def init(opts),
    do: {Keyword.get(opts, :redirect_to), Keyword.get(opts, :allow_principals, false)}

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) when not is_nil(user),
    do: conn

  def call(%Plug.Conn{assigns: %{current_principal: principal}} = conn, {_redirect_to, true})
      when not is_nil(principal),
      do: conn

  def call(conn, {redirect_to, _allow_principals}), do: refuse(conn, redirect_to)

  # Called directly with a redirect path (or nil), without init/1.
  def call(conn, redirect_to) when is_binary(redirect_to) or is_nil(redirect_to),
    do: call(conn, {redirect_to, false})

  defp refuse(conn, redirect_to), do: Refusal.refuse(conn, Error.new(:unauthorized), redirect_to)
end
