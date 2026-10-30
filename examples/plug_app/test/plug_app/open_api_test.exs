defmodule PlugApp.OpenAPITest do
  use PlugApp.ConnCase, async: true

  test "the auth API is described, and browsable" do
    spec = json(get_path("/auth/open-api/generate-schema"))
    assert spec["openapi"] == "3.1.1"
    assert spec["servers"] == [%{"url" => "http://localhost:4001/auth"}]
    assert spec["paths"]["/sign-in/email"]["post"]["tags"] == ["EmailPassword"]
    assert spec["paths"]["/sign-in/magic-link"]["post"]["tags"] == ["MagicLink"]

    conn = get_path("/auth/reference")
    assert conn.status == 200
    assert conn.resp_body =~ ~s(data-url="http://localhost:4001/auth/open-api/generate-schema")
  end
end
