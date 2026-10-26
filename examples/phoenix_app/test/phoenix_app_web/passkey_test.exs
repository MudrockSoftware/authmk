defmodule PhoenixAppWeb.PasskeyTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing.FakeAuthenticator

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "register a passkey, then sign in with it", %{conn: conn} do
    authenticator = FakeAuthenticator.new(origin: "http://localhost:4000")
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", user)

    conn = conn |> recycle() |> from_browser() |> post("/auth/passkey/generate-register-options")
    response = FakeAuthenticator.register(authenticator, json_response(conn, 200))

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/passkey/verify-registration", %{response: response})

    assert json_response(conn, 200)["passkey"]

    conn = conn |> recycle() |> get("/auth/passkey/list-user-passkeys")
    assert [%{"device_type" => "single_device"}] = json_response(conn, 200)

    conn = conn |> recycle() |> from_browser() |> post("/auth/sign-out")

    conn =
      conn |> recycle() |> from_browser() |> post("/auth/passkey/generate-authenticate-options")

    {_authenticator, response} =
      FakeAuthenticator.authenticate(authenticator, json_response(conn, 200))

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/passkey/verify-authentication", %{response: response})

    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"
  end
end
