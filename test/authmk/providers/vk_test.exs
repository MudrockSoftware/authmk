defmodule Authmk.Providers.VKTest do
  use Authmk.Test.ProviderCase, provider: :vk

  alias Authmk.Test.FakeProvider

  @user %{
    "user_id" => 1_234_567,
    "first_name" => "Ada",
    "last_name" => "Lovelace",
    "email" => "ada@example.com",
    "avatar" => "https://sun.userapi.com/ada.jpg"
  }

  # VK ID takes the access token and client id in a POSTed form.
  defp user_info(user) do
    fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)

      case URI.decode_query(body) do
        %{"access_token" => "access-" <> _, "client_id" => "client-id"} ->
          {200, %{"user" => user}}

        _invalid ->
          {401, %{"error" => "invalid_token"}}
      end
    end
  end

  test "signs in with the VK ID profile, using PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: %{"/oauth2/user_info" => user_info(@user)})

    assert url =~ "https://id.vk.com/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "email phone"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://sun.userapi.com/ada.jpg"
  end

  test "the device_id VK sends with the code goes back in the token request", %{
    browser: browser,
    auth: auth
  } do
    test = self()

    token = fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      send(test, {:token_form, URI.decode_query(body)})
      %{"access_token" => "access-1", "token_type" => "bearer", "user_id" => 1_234_567}
    end

    FakeProvider.stub(auth,
      routes: %{"/oauth2/auth" => token, "/oauth2/user_info" => user_info(@user)}
    )

    {browser, conn} = post(browser, "/sign-in/social", %{provider: "vk", callback_url: "/done"})
    params = Map.put(FakeProvider.approve(json(conn)["url"]), "device_id", "device-1")
    {_browser, conn} = get(browser, "/callback/vk", params)

    assert redirected_to(conn) == "/done"
    assert_received {:token_form, %{"device_id" => "device-1", "code_verifier" => _}}
  end

  test "users who share no email can't sign in", %{browser: browser, auth: auth} do
    FakeProvider.stub(auth,
      routes: %{"/oauth2/user_info" => user_info(Map.delete(@user, "email"))}
    )

    {browser, conn} = post(browser, "/sign-in/social", %{provider: "vk", callback_url: "/done"})
    {_browser, conn} = get(browser, "/callback/vk", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=email_not_found"
  end
end
