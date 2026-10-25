defmodule Authmk.Providers.TikTokTest do
  use Authmk.Test.ProviderCase, provider: :tiktok, provider_opts: [scopes: ["video.list"]]

  alias Authmk.Test.FakeProvider

  @user %{
    "open_id" => "tiktok-open-id",
    "display_name" => "Ada Lovelace",
    "username" => "ada",
    "avatar_large_url" => "https://p16.tiktokcdn.com/ada.jpeg"
  }

  # TikTok's token endpoint: the client key and secret in the form, never a
  # `client_id`, and no PKCE verifier.
  defp token_endpoint(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)
    credentials = %{"client_key" => "client-id", "client_secret" => "client-secret"}

    cond do
      Map.take(form, ["client_key", "client_secret"]) != credentials or
          Map.has_key?(form, "client_id") ->
        {401, %{"error" => "invalid_client"}}

      form["grant_type"] == "authorization_code" and form["code"] == "code:no-pkce" and
          not Map.has_key?(form, "code_verifier") ->
        {200, %{"access_token" => "access", "refresh_token" => "refresh", "expires_in" => 86_400}}

      form["grant_type"] == "refresh_token" and form["refresh_token"] == "refresh" ->
        {200,
         %{"access_token" => "refreshed", "refresh_token" => "refresh", "expires_in" => 86_400}}

      true ->
        {400, %{"error" => "invalid_grant"}}
    end
  end

  defp routes(user) do
    %{"/v2/oauth/token/" => &token_endpoint/1, "/v2/user/info/" => %{"data" => %{"user" => user}}}
  end

  test "signs in with client_key and a placeholder email", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: routes(@user))

    assert url =~ "https://www.tiktok.com/v2/auth/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["client_key"] == "client-id"
    refute Map.has_key?(query, "client_id")
    refute Map.has_key?(query, "code_challenge")
    assert query["scope"] == "user.info.profile,video.list"

    assert user["email"] == "tiktok-open-id@tiktok.placeholder.invalid"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://p16.tiktokcdn.com/ada.jpeg"
  end

  test "falls back to the username", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: routes(Map.delete(@user, "display_name")))

    assert user["name"] == "ada"
  end

  test "an email from TikTok replaces the placeholder, still unverified", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: routes(Map.put(@user, "email", "ada@example.com")))

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
  end

  test "refreshes tokens with client_key", %{browser: browser, auth: auth} do
    FakeProvider.stub(auth, routes: routes(@user))

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "tiktok", callback_url: "/done"})

    {browser, conn} = get(browser, "/callback/tiktok", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) == "/done"

    {_browser, conn} = post(browser, "/refresh-token", %{provider_id: "tiktok"})
    assert json(conn)["access_token"] == "refreshed"
  end
end
