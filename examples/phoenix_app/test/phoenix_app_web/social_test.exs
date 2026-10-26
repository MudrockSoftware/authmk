defmodule PhoenixAppWeb.SocialTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  # GitHub's token endpoint and API, as far as sign-in uses them.
  defp stub_github do
    Req.Test.stub(PhoenixApp.Providers, fn conn ->
      case conn.request_path do
        "/login/oauth/access_token" ->
          Req.Test.json(conn, %{"access_token" => "gho_1", "token_type" => "bearer"})

        "/user" ->
          Req.Test.json(conn, %{"id" => 1, "login" => "ada", "name" => "Ada", "email" => nil})

        "/user/emails" ->
          Req.Test.json(conn, [
            %{"email" => "ada@example.com", "primary" => true, "verified" => true}
          ])
      end
    end)
  end

  test "the home page offers GitHub", %{conn: conn} do
    assert html_response(get(conn, ~p"/"), 200) =~ "Sign in with Github"
  end

  test "sign in with GitHub, then see the account page", %{conn: conn} do
    stub_github()

    conn =
      conn
      |> from_browser()
      |> post("/auth/sign-in/social", %{provider: "github", callback_url: "/account"})

    url = json_response(conn, 200)["url"]
    assert url =~ "https://github.com/login/oauth/authorize?"
    state = URI.decode_query(URI.parse(url).query)["state"]

    # GitHub sends the user back with a code.
    conn = conn |> recycle() |> get("/auth/callback/github", %{code: "code-1", state: state})
    assert redirected_to(conn) == "/account"

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ "Ada"
  end
end
