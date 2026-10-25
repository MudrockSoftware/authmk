defmodule Authmk.Plug.RequireAuthenticated do
  @moduledoc """
  Stops requests without a signed-in user. Use after `Authmk.Plug.FetchSession`.

      plug Authmk.Plug.RequireAuthenticated                      # 401 JSON
      plug Authmk.Plug.RequireAuthenticated, redirect_to: "/sign-in"
  """

  @behaviour Plug

  import Plug.Conn

  alias Authmk.Error

  @impl true
  def init(opts), do: Keyword.get(opts, :redirect_to)

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _redirect_to) when not is_nil(user),
    do: conn

  def call(conn, nil) do
    error = Error.new(:unauthorized)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.status, JSON.encode!(Error.to_map(error)))
    |> halt()
  end

  def call(conn, redirect_to) do
    conn |> put_resp_header("location", redirect_to) |> send_resp(302, "") |> halt()
  end
end
