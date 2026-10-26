defmodule PlugApp.PasswordlessTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  import Swoosh.TestAssertions

  test "sign in with a link sent by email" do
    conn = post_json("/auth/sign-in/magic-link", %{email: "ada@example.com", callback_url: "/me"})
    assert json(conn) == %{"status" => true}

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://\S+}, email.text_body)
      send(self(), {:link, url})
    end)

    assert_received {:link, url}
    %URI{path: path, query: query} = URI.parse(url)
    conn = Plug.Test.conn(:get, path <> "?" <> query) |> call()
    assert get_resp_header(conn, "location") == ["/me"]
    assert json(get_path("/me", cookies(conn)))["email"] == "ada@example.com"
  end

  test "sign in with a code sent by email" do
    conn =
      post_json("/auth/email-otp/send-verification-otp", %{
        email: "ada@example.com",
        type: "sign-in"
      })

    assert json(conn) == %{"success" => true}

    assert_email_sent(fn email ->
      [_, code] = Regex.run(~r/(\d{6})/, email.text_body)
      send(self(), {:code, code})
    end)

    assert_received {:code, code}
    conn = post_json("/auth/sign-in/email-otp", %{email: "ada@example.com", otp: code})
    assert get_path("/me", cookies(conn)).status == 200
  end
end
