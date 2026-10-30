defmodule Authmk.Plug.Refusal do
  @moduledoc false
  # How authmk's plugs turn a request away: the error as JSON, or a redirect
  # for browser pages.

  import Plug.Conn

  alias Authmk.Error

  def refuse(conn, %Error{} = error, nil) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.status, JSON.encode!(Error.to_map(error)))
    |> halt()
  end

  def refuse(conn, _error, redirect_to) do
    conn |> put_resp_header("location", redirect_to) |> send_resp(302, "") |> halt()
  end
end
