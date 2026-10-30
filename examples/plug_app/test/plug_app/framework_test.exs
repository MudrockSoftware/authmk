defmodule PlugApp.FrameworkTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Authmk.Testing

  defp post_form(path, params, cookies \\ %{}) do
    conn =
      Plug.Test.conn(:post, path, URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("origin", "http://localhost:4001")
      |> put_req_header("referer", "http://localhost:4001/sign-in-form")

    Enum.reduce(cookies, conn, fn {name, value}, conn -> put_req_cookie(conn, name, value) end)
    |> call()
  end

  test "the sign-in page works without JavaScript" do
    Testing.create_user(PlugApp.Auth, email: "ada@example.com", password: "correct horse battery")
    assert get_path("/sign-in-form").resp_body =~ ~s(name="authmk_redirect" value="/me")

    wrong =
      post_form("/auth/sign-in/email", %{
        authmk_redirect: "/me",
        email: "ada@example.com",
        password: "no"
      })

    assert wrong.status == 303
    assert get_resp_header(wrong, "location") == ["/sign-in-form?error=invalid_credentials"]

    assert get_path("/sign-in-form?error=invalid_credentials").resp_body =~
             "Invalid email or password"

    ok =
      post_form("/auth/sign-in/email", %{
        authmk_redirect: "/me",
        email: "ada@example.com",
        password: "correct horse battery"
      })

    assert get_resp_header(ok, "location") == ["/me"]
    assert json(get_path("/me", cookies(ok)))["email"] == "ada@example.com"

    # The app's own sign-out ends the session.
    out = post_form("/sign-out", %{}, cookies(ok))
    assert out.status == 303
    assert get_path("/me", cookies(ok)).status == 401
  end

  test "admins only" do
    ada = Testing.create_user(PlugApp.Auth, email: "ada@example.com")
    boss = Testing.create_user(PlugApp.Auth, email: "boss@example.com", role: "admin")

    assert get_path("/admin").status == 401

    assert Plug.Test.conn(:get, "/admin")
           |> Testing.sign_in(PlugApp.Auth, ada)
           |> call()
           |> Map.get(:status) == 403

    assert Plug.Test.conn(:get, "/admin")
           |> Testing.sign_in(PlugApp.Auth, boss)
           |> call()
           |> Map.get(:status) == 200
  end

  test "a browser app on a trusted origin reads answers (CORS with credentials)" do
    conn =
      Plug.Test.conn(
        :post,
        "/auth/sign-up/email",
        JSON.encode!(%{email: "ada@example.com", password: "correct horse battery", name: "Ada"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://localhost:4100")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4100"]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "the mobile app signs in through a link and gets a token back" do
    Testing.create_user(PlugApp.Auth, email: "ada@example.com")

    post_json("/auth/sign-in/magic-link", %{
      email: "ada@example.com",
      callback_url: "plugapp://signed-in"
    })

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://\S+}, email.text_body)
      send(self(), {:link, url})
    end)

    assert_received {:link, url}
    %URI{path: path, query: query} = URI.parse(url)

    [location] =
      Plug.Test.conn(:get, path <> "?" <> query) |> call() |> get_resp_header("location")

    "plugapp://signed-in?token=" <> token = location

    # The app trades it for a session of its own.
    app = post_json("/auth/one-time-token/verify", %{token: token})
    assert json(app)["user"]["email"] == "ada@example.com"
  end
end
