defmodule Authmk.Providers.TwitchTest do
  use Authmk.Test.ProviderCase, provider: :twitch

  alias Authmk.Test.FakeProvider

  def claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://id.twitch.tv/oauth2",
        "aud" => "client-id",
        "sub" => "twitch-user",
        "preferred_username" => "ada",
        "email" => "ada@example.com",
        "email_verified" => true,
        "picture" => "https://static-cdn.jtvnw.net/ada.png",
        "iat" => now,
        "exp" => now + 600
      },
      overrides
    )
  end

  # A token response with an ID token, and Twitch's keys to check it.
  def id_token(claims), do: FakeProvider.signed_id_token(claims, "/oauth2/keys")

  test "signs in with the ID token's claims, without PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, id_token(claims()))

    assert url =~ "https://id.twitch.tv/oauth2/authorize?"
    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "user:read:email openid"
    refute Map.has_key?(query, "code_challenge")

    assert JSON.decode!(query["claims"]) == %{
             "id_token" => %{
               "email" => nil,
               "email_verified" => nil,
               "preferred_username" => nil,
               "picture" => nil
             }
           }

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "ada"
    assert user["image"] == "https://static-cdn.jtvnw.net/ada.png"
  end

  test "an unverified Twitch email stays unverified", %{browser: browser} do
    %{user: user} = sign_in(browser, id_token(claims(%{"email_verified" => false})))
    assert user["email_verified"] == false
  end

  test "an ID token Twitch didn't sign fails", %{browser: browser, auth: auth} do
    {other_key, _jwks} = FakeProvider.signing_key()
    FakeProvider.stub(auth, id_token: FakeProvider.id_token(other_key, claims()))

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "twitch", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/twitch", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=invalid_id_token"
  end

  test "sign-in fails without an ID token", %{browser: browser, auth: auth} do
    FakeProvider.stub(auth, [])

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "twitch", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/twitch", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end
end

defmodule Authmk.Providers.TwitchClaimsTest do
  # A second Twitch provider under its own name, so it gets its own auth module.
  use Authmk.Test.ProviderCase,
    provider: :twitch_claims,
    provider_opts: [provider: Authmk.OAuth.Providers.Twitch, claims: ["picture"]]

  alias Authmk.Providers.TwitchTest

  test "claims: replaces the extra claims, keeping email", %{browser: browser} do
    %{url: url} = sign_in(browser, TwitchTest.id_token(TwitchTest.claims()))

    query = URI.decode_query(URI.parse(url).query)

    assert JSON.decode!(query["claims"]) == %{
             "id_token" => %{"email" => nil, "email_verified" => nil, "picture" => nil}
           }
  end
end
