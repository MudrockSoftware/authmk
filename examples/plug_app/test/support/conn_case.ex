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

  def call(conn), do: PlugApp.Router.call(conn, PlugApp.Router.init([]))
end
