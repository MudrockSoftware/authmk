defmodule PhoenixAppWeb.SSOTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  test "people at acme.example sign in with acme's identity provider", %{conn: conn} do
    PhoenixApp.IdentityProvider.stub(nil)

    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-in/sso", %{email: "ada@acme.example", callback_url: "/account"})

    url = json_response(conn, 200)["url"]
    query = URI.decode_query(URI.parse(url).query)
    PhoenixApp.IdentityProvider.stub(query["nonce"])

    conn =
      conn
      |> recycle()
      |> get("/auth/sso/callback/acme", %{code: "a-code", state: query["state"]})

    assert redirected_to(conn) == "/account"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"
  end
end
