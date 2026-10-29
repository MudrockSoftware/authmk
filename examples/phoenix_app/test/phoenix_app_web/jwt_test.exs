defmodule PhoenixAppWeb.JWTTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a JWT for the session, checked with the published keys", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)
    conn = conn |> recycle() |> get("/auth/token")
    token = json_response(conn, 200)["token"]

    assert {:ok, %{"email" => "ada@example.com"}} = Authmk.Plugins.JWT.verify(PhoenixApp.Auth, token)
    assert [_key] = build_conn() |> get("/auth/jwks") |> json_response(200) |> Map.fetch!("keys")
  end
end
