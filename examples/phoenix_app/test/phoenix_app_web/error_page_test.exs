defmodule PhoenixAppWeb.ErrorPageTest do
  use PhoenixAppWeb.ConnCase, async: true

  test "a failed sign-in lands on authmk's themed error page", %{conn: conn} do
    page = conn |> get("/auth/error", error: "access_denied") |> html_response(400)
    assert page =~ ~s(id="authmk-page")
    assert page =~ ~s("code":"access_denied")

    [_, asset] = Regex.run(~r{"\./(_app/immutable/entry/start\.[^"]+)"}, page)
    assert build_conn() |> get("/auth/" <> asset) |> response(200)
  end
end
