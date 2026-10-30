defmodule PhoenixAppWeb.APIClientsTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Authmk.Testing

  test "a browser app on a trusted origin reads answers (CORS with credentials)", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4100")
      |> post("/auth/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse battery",
        name: "Ada"
      })

    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4100"]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "the mobile app signs in through a link and gets a token back", %{conn: conn} do
    Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")

    conn
    |> put_req_header("origin", "http://localhost:4000")
    |> post("/auth/sign-in/magic-link", %{
      email: "ada@example.com",
      callback_url: "phoenixapp://signed-in"
    })

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://\S+}, email.text_body)
      send(self(), {:link, url})
    end)

    assert_received {:link, url}
    "phoenixapp://signed-in?token=" <> token = build_conn() |> get(url) |> redirected_to()

    # The app trades it for a session of its own.
    app = build_conn() |> post("/auth/one-time-token/verify", %{token: token})
    assert json_response(app, 200)["user"]["email"] == "ada@example.com"
  end
end
