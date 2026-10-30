defmodule PlugApp.ErrorPageTest do
  use PlugApp.ConnCase, async: true

  test "a failed sign-in lands on authmk's themed error page" do
    page = get_path("/auth/error?error=access_denied")
    assert page.status == 400
    assert page.resp_body =~ ~s(id="authmk-page")
    assert page.resp_body =~ ~s("code":"access_denied")
    assert get_resp_header(page, "x-frame-options") == ["DENY"]

    [_, asset] = Regex.run(~r{"\./(_app/immutable/entry/start\.[^"]+)"}, page.resp_body)
    assert get_path("/auth/" <> asset).status == 200
  end
end
