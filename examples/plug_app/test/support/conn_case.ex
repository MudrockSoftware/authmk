defmodule PlugApp.ConnCase do
  @moduledoc """
  Test case for requests against `PlugApp.Router`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import PlugApp.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(PlugApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @origin "http://localhost:4001"

  @doc "Sends a request through the router. POSTs carry JSON and a browser-like Origin header."
  def call(conn), do: PlugApp.Router.call(conn, PlugApp.Router.init([]))

  def post_json(path, params, cookies \\ %{}) do
    Plug.Test.conn(:post, path, JSON.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("origin", @origin)
    |> put_cookies(cookies)
    |> call()
  end

  def get_path(path, cookies \\ %{}) do
    Plug.Test.conn(:get, path) |> put_cookies(cookies) |> call()
  end

  @doc "Cookies a browser would keep from a response."
  def cookies(conn) do
    for {name, %{value: value} = cookie} <- conn.resp_cookies,
        cookie[:max_age] != 0,
        into: %{},
        do: {name, value}
  end

  def json(conn), do: JSON.decode!(conn.resp_body)

  defp put_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, value}, conn ->
      Plug.Test.put_req_cookie(conn, name, value)
    end)
  end
end
