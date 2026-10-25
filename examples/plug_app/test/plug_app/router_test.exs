defmodule PlugApp.RouterTest do
  use PlugApp.ConnCase, async: true

  test "GET / responds" do
    conn = conn(:get, "/") |> call()
    assert conn.status == 200
  end
end
