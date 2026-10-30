defmodule PhoenixAppWeb.OpenAPITest do
  use PhoenixAppWeb.ConnCase, async: true

  test "the auth API is described, and browsable", %{conn: conn} do
    spec = json_response(get(conn, "/auth/open-api/generate-schema"), 200)
    assert spec["openapi"] == "3.1.1"
    assert spec["servers"] == [%{"url" => "http://localhost:4000/auth"}]
    assert spec["paths"]["/sign-in/email"]["post"]["tags"] == ["EmailPassword"]
    assert spec["paths"]["/sign-in/magic-link"]["post"]["tags"] == ["MagicLink"]

    html = html_response(get(conn, "/auth/reference"), 200)
    assert html =~ ~s(data-url="http://localhost:4000/auth/open-api/generate-schema")
  end
end
