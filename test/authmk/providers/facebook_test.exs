defmodule Authmk.Providers.FacebookTest do
  use Authmk.Test.ProviderCase,
    provider: :facebook,
    provider_opts: [config_id: "config-1", fields: ["birthday"]]

  alias Authmk.OAuth.Providers
  alias Authmk.Test.{FakeProvider, Repo}

  @profile %{
    "id" => "10",
    "name" => "Ada Lovelace",
    "email" => "ada@example.com",
    "picture" => %{"data" => %{"url" => "https://graph.facebook.com/10/picture"}}
  }

  # Facebook's token check, answered for the app's own access token only.
  defp debug_token(data) do
    test = self()

    fn conn ->
      send(test, {:debug_token, conn.query_params})
      true = conn.query_params["access_token"] == "client-id|client-secret"
      %{"data" => data}
    end
  end

  defp graph(debug, profile) do
    test = self()

    me = fn conn ->
      send(test, {:me, conn.query_params})
      profile
    end

    [public_routes: %{"/debug_token" => debug_token(debug)}, routes: %{"/me" => me}]
  end

  @valid %{"is_valid" => true, "app_id" => "client-id", "user_id" => "10"}

  defp callback_location(browser, auth, fake) do
    FakeProvider.stub(auth, fake)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "facebook", callback_url: "/done"})

    url = json(conn)["url"]
    {_browser, conn} = get(browser, "/callback/facebook", FakeProvider.approve(url))
    redirected_to(conn)
  end

  test "signs in with a token Facebook confirms was issued to this app", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, graph(@valid, @profile))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "www.facebook.com/v24.0/dialog/oauth"
    assert query["scope"] == "email public_profile"
    assert query["config_id"] == "config-1"
    refute Map.has_key?(query, "code_challenge")

    assert_received {:debug_token, %{"input_token" => "access-" <> _}}
    assert_received {:me, %{"fields" => "id,name,email,picture,birthday"}}

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://graph.facebook.com/10/picture"
  end

  test "the email is verified when the Graph profile says so", %{browser: browser} do
    %{user: user} = sign_in(browser, graph(@valid, Map.put(@profile, "email_verified", true)))
    assert user["email_verified"] == true
  end

  test "tokens of other apps, invalid tokens and other users' profiles are refused",
       %{browser: browser, auth: auth} do
    for {debug, profile} <- [
          {%{@valid | "app_id" => "someone-elses-app"}, @profile},
          {%{@valid | "is_valid" => false}, @profile},
          {Map.delete(@valid, "user_id"), @profile},
          {@valid, %{@profile | "id" => "11"}}
        ] do
      location = callback_location(browser, auth, graph(debug, profile))
      assert location =~ "error=unable_to_get_user_info"
    end

    assert Repo.aggregate("users", :count) == 0
  end

  test "the client secret is required" do
    assert_raise NimbleOptions.ValidationError, ~r/client_secret/, fn ->
      Providers.build(facebook: [client_id: "client-id"])
    end
  end

  describe "Limited Login ID tokens" do
    setup %{auth: auth} do
      {jwk, jwks} = FakeProvider.signing_key()
      FakeProvider.stub(auth, jwks: jwks, jwks_path: "/.well-known/oauth/openid/jwks/")
      %{jwk: jwk}
    end

    defp claims(overrides \\ %{}) do
      now = System.system_time(:second)

      Map.merge(
        %{
          "iss" => "https://www.facebook.com",
          "aud" => "client-id",
          "sub" => "10",
          "email" => "ada@example.com",
          "name" => "Ada Lovelace",
          "picture" => "https://platform-lookaside.fbsbx.com/10/picture",
          "iat" => now,
          "exp" => now + 600,
          "nonce" => "n-1"
        },
        overrides
      )
    end

    defp sign_in_with_id_token(browser, token) do
      post(browser, "/sign-in/social", %{
        provider: "facebook",
        id_token: %{token: token, nonce: "n-1"}
      })
    end

    test "a valid token signs in with an unverified email", %{browser: browser, jwk: jwk} do
      {browser, conn} = sign_in_with_id_token(browser, FakeProvider.id_token(jwk, claims()))
      assert json(conn)["user"]["email"] == "ada@example.com"

      {_browser, conn} = get(browser, "/get-session")
      user = json(conn)["user"]
      assert user["email_verified"] == false
      assert user["name"] == "Ada Lovelace"
      assert user["image"] == "https://platform-lookaside.fbsbx.com/10/picture"
    end

    test "tokens for another app or issuer, or with another nonce, are refused",
         %{browser: browser, jwk: jwk} do
      for overrides <- [
            %{"aud" => "someone-else"},
            %{"iss" => "https://evil.example"},
            %{"nonce" => "other"}
          ] do
        {_browser, conn} =
          sign_in_with_id_token(browser, FakeProvider.id_token(jwk, claims(overrides)))

        assert json(conn)["error"]["code"] == "invalid_id_token"
      end

      assert Repo.aggregate("users", :count) == 0
    end

    test "an ID token from the token endpoint is used instead of the Graph API",
         %{browser: browser} do
      fake =
        FakeProvider.signed_id_token(
          Map.delete(claims(), "nonce"),
          "/.well-known/oauth/openid/jwks/"
        )

      %{user: user} = sign_in(browser, fake)
      assert user["email"] == "ada@example.com"
      assert user["email_verified"] == false
    end
  end
end
