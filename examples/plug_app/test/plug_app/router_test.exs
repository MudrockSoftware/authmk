defmodule PlugApp.RouterTest do
  use PlugApp.ConnCase, async: true

  test "GET / responds" do
    assert get_path("/").status == 200
  end
end
