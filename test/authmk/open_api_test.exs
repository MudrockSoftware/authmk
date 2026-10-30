defmodule Authmk.OpenAPITest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OpenAPI

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      app_name: "Acme",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.TwoFactor,
        {Authmk.Plugins.OpenAPI, nonce: "n0nce\"><script>"}
      ]
  end

  defmodule NoReferenceAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.OpenAPI, reference: false}]
  end

  @moduletag auth: Auth

  defp spec(browser) do
    {_browser, conn} = get(browser, "/open-api/generate-schema")
    assert conn.status == 200
    json(conn)
  end

  test "every endpoint, with its params, grouped by plugin", %{browser: browser} do
    spec = spec(browser)
    assert spec["openapi"] == "3.1.1"
    assert spec["info"]["title"] == "Acme API"
    assert spec["servers"] == [%{"url" => "http://localhost:4000/auth"}]

    sign_in = spec["paths"]["/sign-in/email"]["post"]
    assert sign_in["operationId"] == "sign_in_email"
    assert sign_in["tags"] == ["EmailPassword"]
    body = sign_in["requestBody"]["content"]["application/json"]["schema"]
    assert body["properties"]["email"] == %{"type" => "string"}
    assert body["properties"]["remember_me"]["type"] == "boolean"
    assert Enum.sort(body["required"]) == ["email", "password"]
    refute Map.has_key?(sign_in, "security")

    get_session = spec["paths"]["/get-session"]["get"]
    assert get_session["tags"] == ["Core"]

    assert [%{"name" => "disable_cookie_cache", "in" => "query", "schema" => schema}] =
             get_session["parameters"]

    assert schema == %{"type" => "boolean", "default" => false}

    # Path params, and both methods on one path.
    callback = spec["paths"]["/callback/{provider}"]
    assert Map.keys(callback) == ["get", "post"]

    assert %{"name" => "provider", "in" => "path", "required" => true} =
             Enum.find(callback["get"]["parameters"], &(&1["in"] == "path"))

    # Endpoints that need a session say so.
    assert spec["paths"]["/two-factor/enable"]["post"]["tags"] == ["TwoFactor"]

    assert spec["paths"]["/list-sessions"]["get"]["security"] == [
             %{"session_cookie" => []},
             %{"bearer" => []}
           ]

    assert spec["components"]["securitySchemes"]["session_cookie"]["name"] ==
             "authmk.session_token"
  end

  test "models show only their public fields", %{browser: browser} do
    schemas = spec(browser)["components"]["schemas"]

    user = schemas["User"]
    assert user["properties"]["email"] == %{"type" => "string"}
    assert user["properties"]["image"] == %{"type" => ["string", "null"]}
    assert user["properties"]["two_factor_enabled"]["type"] in ["boolean", ["boolean", "null"]]
    assert "email" in user["required"]

    refute Map.has_key?(schemas["Account"]["properties"], "password")
    refute Map.has_key?(schemas["Session"]["properties"], "token")
    assert schemas["Session"]["properties"]["user_id"]["type"] == "string"
    assert schemas["Error"]["properties"]["error"]["required"] == ["code", "message"]
  end

  test "operation ids are unique and every reference resolves", %{browser: browser} do
    spec = spec(browser)
    operations = for {_path, methods} <- spec["paths"], {_method, op} <- methods, do: op
    ids = Enum.map(operations, & &1["operationId"])
    assert ids == Enum.uniq(ids)

    refs =
      spec |> JSON.encode!() |> then(&Regex.scan(~r/"\$ref":"#\/components\/schemas\/(\w+)"/, &1))

    for [_ref, name] <- refs, do: assert(Map.has_key?(spec["components"]["schemas"], name))
  end

  test "spec/1 gives the same document in Elixir", %{browser: browser} do
    assert OpenAPI.spec(Auth) |> JSON.encode!() |> JSON.decode!() == spec(browser)
  end

  test "the reference page loads one pinned, integrity-checked script", %{browser: browser} do
    {_browser, conn} = get(browser, "/reference")
    assert conn.status == 200
    assert ["text/html" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    html = conn.resp_body

    assert html =~ ~s(data-url="http://localhost:4000/auth/open-api/generate-schema")
    assert html =~ ~r{src="https://cdn\.jsdelivr\.net/npm/@scalar/api-reference@\d+\.\d+\.\d+/}
    assert html =~ ~s(integrity="sha384-)
    assert html =~ ~s(crossorigin="anonymous")
    # Options are escaped, and there's no inline script to allow.
    assert html =~ ~s(nonce="n0nce&quot;&gt;&lt;script&gt;")
    assert html =~ "&quot;theme&quot;:&quot;default&quot;"
    assert length(Regex.scan(~r/<script/, html)) == 2
    assert length(Regex.scan(~r{<script[^>]*></script>}, html)) == 2
  end

  @tag auth: NoReferenceAuth
  test "the reference page can be turned off", %{browser: browser} do
    {browser, conn} = get(browser, "/reference")
    assert conn.status == 404
    {_browser, conn} = get(browser, "/open-api/generate-schema")
    assert conn.status == 200
  end
end
