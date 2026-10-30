defmodule PhoenixAppWeb.ServiceAccountTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a service account calls the API with its key", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/service-account/create", %{name: "Nightly export"})

    id = json_response(conn, 200)["id"]

    conn =
      conn |> recycle() |> from_browser() |> post("/auth/service-account/create-key", %{id: id})

    key = json_response(conn, 200)["key"]

    conn = build_conn() |> put_req_header("x-api-key", key) |> get("/api/whoami")
    assert json_response(conn, 200) == %{"type" => "service_account", "name" => "Nightly export"}

    conn = build_conn() |> put_req_header("x-api-key", key) |> get(~p"/account")
    assert redirected_to(conn) == "/"

    conn = build_conn() |> get("/api/whoami")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end
end
