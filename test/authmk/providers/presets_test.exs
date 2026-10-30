defmodule Authmk.Providers.HubSpotTest do
  use Authmk.Test.ProviderCase, provider: :hubspot

  test "signs in as the user who authorized the app", %{browser: browser} do
    info = %{"user" => "ada@example.com", "user_id" => 123, "hub_id" => 9}

    %{url: url, user: user} =
      sign_in(browser, public_routes: %{"/oauth/v1/access-tokens/*" => info})

    assert url =~ "https://app.hubspot.com/oauth/authorize?"
    assert URI.decode_query(URI.parse(url).query)["scope"] == "oauth"
    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
  end

  # The token is one path segment, whatever it holds.
  test "the token is escaped in the token info path", %{browser: browser} do
    test = self()

    info = fn conn ->
      send(test, {:token_segment, List.last(conn.path_info)})
      %{"user" => "ada@example.com", "user_id" => 1}
    end

    sign_in(browser,
      public_routes: %{"/oauth/v1/access-tokens/*" => info},
      access_token: "a/b c?d"
    )

    assert_received {:token_segment, "a%2Fb%20c%3Fd"}
  end
end

defmodule Authmk.Providers.GumroadTest do
  use Authmk.Test.ProviderCase, provider: :gumroad

  test "signs in with the Gumroad user", %{browser: browser} do
    answer = %{
      "success" => true,
      "user" => %{"user_id" => "g1", "email" => "ada@example.com", "name" => "Ada"}
    }

    %{url: url, user: user} = sign_in(browser, routes: %{"/v2/user" => answer})

    assert url =~ "https://gumroad.com/oauth/authorize?"
    assert user["name"] == "Ada"
    assert user["email_verified"] == false
  end
end

defmodule Authmk.Providers.PatreonTest do
  use Authmk.Test.ProviderCase, provider: :patreon

  test "signs in with the identity, and Patreon's verified flag", %{browser: browser} do
    identity = fn conn ->
      assert conn.query_params["fields"]["user"] =~ "is_email_verified"

      %{
        "data" => %{
          "id" => "p1",
          "attributes" => %{
            "email" => "ada@example.com",
            "full_name" => "Ada Lovelace",
            "image_url" => "https://c8.patreon.com/ada.png",
            "is_email_verified" => true
          }
        }
      }
    end

    %{url: url, user: user} = sign_in(browser, routes: %{"/api/oauth2/v2/identity" => identity})

    assert URI.decode_query(URI.parse(url).query)["scope"] == "identity identity[email]"
    assert user["email_verified"] == true
    assert user["image"] == "https://c8.patreon.com/ada.png"
  end
end

defmodule Authmk.Providers.YandexTest do
  use Authmk.Test.ProviderCase, provider: :yandex

  test "reads the profile with Yandex's OAuth authorization", %{browser: browser} do
    info = fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["OAuth access-" <> _] ->
          %{
            "id" => "y1",
            "login" => "ada",
            "default_email" => "ada@yandex.example",
            "display_name" => "Ada",
            "default_avatar_id" => "abc",
            "is_avatar_empty" => false
          }

        _other ->
          {401, %{"error" => "unauthorized"}}
      end
    end

    %{user: user} = sign_in(browser, routes: %{"/info" => info})

    assert user["email"] == "ada@yandex.example"
    assert user["image"] == "https://avatars.yandex.net/get-yapic/abc/islands-200"
  end
end
