defmodule PhoenixAppWeb.DeviceAuthorizationTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @grant "urn:ietf:params:oauth:grant-type:device_code"

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a TV signs in, approved by a signed-in user", %{conn: conn} do
    codes = build_conn() |> post("/auth/device/code", %{client_id: "tv"}) |> json_response(200)

    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)

    conn
    |> recycle()
    |> from_browser()
    |> post("/auth/device/approve", %{user_code: codes["user_code"]})

    token =
      build_conn()
      |> post("/auth/device/token", %{
        grant_type: @grant,
        device_code: codes["device_code"],
        client_id: "tv"
      })
      |> json_response(200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token["access_token"])
      |> get("/api/whoami")

    assert json_response(conn, 200) == %{"type" => "user", "name" => "Ada"}
  end
end
