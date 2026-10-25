defmodule Authmk.Providers.TwitterTest do
  use Authmk.Test.ProviderCase, provider: :twitter

  @user %{
    "id" => "1234",
    "name" => "Ada Lovelace",
    "username" => "ada",
    "profile_image_url" => "https://pbs.twimg.com/ada.jpg"
  }

  # X serves the profile and the confirmed email from the same path, by
  # `user.fields`. `confirmed_email` is `{status, json}` for the email request.
  defp users_me(confirmed_email) do
    fn conn ->
      case {Plug.Conn.get_req_header(conn, "authorization"), conn.query_params["user.fields"]} do
        {["Bearer " <> _token], "profile_image_url"} -> {200, %{"data" => @user}}
        {["Bearer " <> _token], "confirmed_email"} -> confirmed_email
        _unexpected -> {401, %{"title" => "Unauthorized"}}
      end
    end
  end

  test "signs in with the confirmed email, using PKCE", %{browser: browser} do
    confirmed = {200, %{"data" => %{"confirmed_email" => "ada@example.com"}}}
    %{url: url, user: user} = sign_in(browser, routes: %{"/2/users/me" => users_me(confirmed)})

    assert url =~ "https://x.com/i/oauth2/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "users.read tweet.read offline.access users.email"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://pbs.twimg.com/ada.jpg"
  end

  test "without a confirmed email, the user gets an unverified placeholder", %{browser: browser} do
    forbidden = {403, %{"title" => "Forbidden"}}
    %{user: user} = sign_in(browser, routes: %{"/2/users/me" => users_me(forbidden)})

    assert user["email"] == "1234@twitter.placeholder.invalid"
    assert user["email_verified"] == false
  end

  test "token requests authenticate with HTTP Basic", %{browser: browser} do
    basic = "Basic " <> Base.encode64("client-id:client-secret")

    token = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)

      if Plug.Conn.get_req_header(conn, "authorization") == [basic] and
           form["client_secret"] == nil,
         do: {200, %{"access_token" => "access", "token_type" => "bearer"}},
         else: {401, %{"error" => "invalid_client"}}
    end

    confirmed = {200, %{"data" => %{"confirmed_email" => "ada@example.com"}}}

    %{user: user} =
      sign_in(browser,
        routes: %{"/2/oauth2/token" => token, "/2/users/me" => users_me(confirmed)}
      )

    assert user["email"] == "ada@example.com"
  end
end
