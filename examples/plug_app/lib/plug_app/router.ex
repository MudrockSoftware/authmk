defmodule PlugApp.Router do
  @moduledoc """
  A plain Plug app (no Phoenix) used to exercise authmk.
  """

  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
  plug :dispatch

  get "/" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
