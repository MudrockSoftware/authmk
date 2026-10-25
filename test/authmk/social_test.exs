defmodule Authmk.SocialTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    social_providers: [
      github: [client_id: "github-id", client_secret: "client-secret"],
      google: [client_id: "google-id", client_secret: "client-secret"]
    ],
    advanced: [http_options: [plug: {Req.Test, Authmk.SocialTest.Provider}]]

  @impl Authmk
  def send_verification_email(link, _ctx), do: send(self(), {:email, :verification, link})
end

defmodule Authmk.SocialTest.StrictAuth do
  # No sign-ups through GitHub, tokens encrypted, state in the database.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    social_providers: [
      github: [client_id: "github-id", client_secret: "client-secret", disable_sign_up: true]
    ],
    account: [
      encrypt_oauth_tokens: true,
      store_state: :database,
      account_linking: [trusted_providers: [:github]]
    ],
    advanced: [http_options: [plug: {Req.Test, Authmk.SocialTest.Provider}]]
end

defmodule Authmk.SocialTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{FakeProvider, Repo}

  @moduletag auth: Authmk.SocialTest.Auth

  @profile %{
    "id" => 42,
    "login" => "ada",
    "name" => "Ada Lovelace",
    "email" => nil,
    "avatar_url" => "https://avatars.example/ada"
  }
  @emails [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]

  setup do
    FakeProvider.stub(Authmk.SocialTest.Provider, profile: @profile, emails: @emails)
    :ok
  end

  defp start_github(browser, params \\ %{}) do
    {browser, conn} =
      post(
        browser,
        "/sign-in/social",
        Map.merge(%{provider: "github", callback_url: "/dashboard"}, params)
      )

    {browser, json(conn)["url"]}
  end

  defp sign_in_with_github(browser, params \\ %{}) do
    {browser, url} = start_github(browser, params)
    get(browser, "/callback/github", FakeProvider.approve(url))
  end

  describe "sign-in redirect" do
    test "points to the provider with state, PKCE and the default scopes", %{browser: browser} do
      {browser, url} = start_github(browser)
      query = URI.decode_query(URI.parse(url).query)

      assert url =~ "https://github.com/login/oauth/authorize?"
      assert query["client_id"] == "github-id"
      assert query["redirect_uri"] == "http://localhost:4000/auth/callback/github"
      assert query["scope"] == "read:user user:email"
      assert query["code_challenge_method"] == "S256"
      assert byte_size(query["state"]) >= 32
      assert cookie(browser, "authmk.oauth_state")
    end

    test "rejects unknown providers and untrusted callback URLs", %{browser: browser} do
      {_browser, conn} = post(browser, "/sign-in/social", %{provider: "myspace"})
      assert json(conn)["error"]["code"] == "oauth_provider_not_found"

      {_browser, conn} =
        post(browser, "/sign-in/social", %{
          provider: "github",
          callback_url: "https://evil.example"
        })

      assert json(conn)["error"]["code"] == "invalid_callback_url"
    end
  end

  describe "callback" do
    test "creates the user and account, signs in, and redirects", %{browser: browser} do
      {browser, conn} = sign_in_with_github(browser)
      assert redirected_to(conn) == "/dashboard"
      assert cookie(browser, "authmk.oauth_state") == nil

      {_browser, conn} = get(browser, "/get-session")
      user = json(conn)["user"]
      assert user["email"] == "ada@example.com"
      assert user["email_verified"] == true
      assert user["name"] == "Ada Lovelace"
      assert user["image"] == "https://avatars.example/ada"

      assert [{"github", "42"}] =
               Repo.all(from(a in "accounts", select: {a.provider_id, a.account_id}))
    end

    test "signing in again reuses the user", %{browser: browser} do
      {_browser, _conn} = sign_in_with_github(browser)
      {_browser, _conn} = sign_in_with_github(browser)

      assert Repo.aggregate("users", :count) == 1
      assert Repo.aggregate("accounts", :count) == 1
    end

    test "new users can go to their own page", %{browser: browser} do
      {_browser, conn} = sign_in_with_github(browser, %{new_user_callback_url: "/welcome"})
      assert redirected_to(conn) == "/welcome"

      {_browser, conn} = sign_in_with_github(browser, %{new_user_callback_url: "/welcome"})
      assert redirected_to(conn) == "/dashboard"
    end

    test "fails when the callback comes back to another browser", %{browser: browser} do
      {_starter, url} = start_github(browser)

      {_victim, conn} =
        get(%{browser | cookies: %{}}, "/callback/github", FakeProvider.approve(url))

      assert redirected_to(conn) == "http://localhost:4000/auth/error?error=state_mismatch"
      assert Repo.aggregate("users", :count) == 0
    end

    test "fails with a tampered state or code", %{browser: browser} do
      {starter, url} = start_github(browser)
      params = FakeProvider.approve(url)

      {_browser, conn} = get(starter, "/callback/github", %{params | "state" => "forged"})
      assert redirected_to(conn) =~ "error=state_mismatch"

      {starter, url} = start_github(browser)

      {_browser, conn} =
        get(starter, "/callback/github", %{FakeProvider.approve(url) | "code" => "code:wrong"})

      assert redirected_to(conn) =~ "error=invalid_code"
    end

    test "passes on the provider's error, to the error callback when given", %{browser: browser} do
      {starter, url} = start_github(browser, %{error_callback_url: "/sign-in"})
      state = FakeProvider.approve(url)["state"]

      {_browser, conn} = get(starter, "/callback/github", %{state: state, error: "access_denied"})
      assert redirected_to(conn) == "/sign-in?error=access_denied"
    end

    test "a provider's form post is turned into a GET with the cookies", %{browser: browser} do
      {starter, url} = start_github(browser)
      params = FakeProvider.approve(url)

      {_browser, conn} =
        post(%{starter | origin: "https://appleid.apple.com"}, "/callback/github", params)

      location = redirected_to(conn)
      assert location =~ "http://localhost:4000/auth/callback/github?"
      assert URI.decode_query(URI.parse(location).query) == params
    end
  end

  # Typed, so every database stores a real boolean.
  defp verify_emails(auth),
    do: Repo.update_all(Module.concat(auth, User), set: [email_verified: true])

  describe "existing users with the same email" do
    test "an unverified local account isn't linked: nobody can take it over", %{browser: browser} do
      {_browser, _user} = sign_up(browser)
      {_browser, conn} = sign_in_with_github(browser)

      assert redirected_to(conn) =~ "error=account_not_linked"
      assert Repo.aggregate("accounts", :count) == 1
    end

    test "a verified local account is linked when the provider verified the email too", %{
      browser: browser
    } do
      {_browser, _user} = sign_up(browser)
      verify_emails(Authmk.SocialTest.Auth)

      {_browser, conn} = sign_in_with_github(browser)
      assert redirected_to(conn) == "/dashboard"
      assert Repo.aggregate("accounts", :count) == 2
    end

    test "an email the provider didn't verify isn't linked", %{browser: browser} do
      FakeProvider.stub(Authmk.SocialTest.Provider,
        profile: @profile,
        emails: [%{hd(@emails) | "verified" => false}]
      )

      {_browser, _user} = sign_up(browser)
      verify_emails(Authmk.SocialTest.Auth)

      {_browser, conn} = sign_in_with_github(browser)
      assert redirected_to(conn) =~ "error=account_not_linked"
    end
  end

  describe "linked accounts" do
    test "link-social adds a provider to the signed-in user", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {browser, conn} =
        post(browser, "/link-social", %{provider: "github", callback_url: "/settings"})

      {browser, conn} = get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))
      assert redirected_to(conn) == "/settings"

      {browser, conn} = get(browser, "/list-accounts")
      assert Enum.map(json(conn), & &1["provider_id"]) |> Enum.sort() == ["credential", "github"]

      {browser, conn} = post(browser, "/unlink-account", %{provider_id: "github"})
      assert json(conn) == %{"status" => true}

      {_browser, conn} = post(browser, "/unlink-account", %{provider_id: "credential"})
      assert json(conn)["error"]["code"] == "cannot_unlink_last_account"
    end

    test "link-social refuses a provider email that isn't the user's", %{browser: browser} do
      {browser, _user} = sign_up(browser, %{email: "grace@example.com"})
      {browser, conn} = post(browser, "/link-social", %{provider: "github"})
      {_browser, conn} = get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))

      assert redirected_to(conn) =~ "error=email_doesnt_match"
    end

    test "get-access-token refreshes an expired token", %{browser: browser} do
      FakeProvider.stub(Authmk.SocialTest.Provider,
        profile: @profile,
        emails: @emails,
        expires_in: 1
      )

      {browser, _conn} = sign_in_with_github(browser)

      Repo.update_all("accounts",
        set: [access_token_expires_at: DateTime.add(DateTime.utc_now(), -60)]
      )

      {_browser, conn} = post(browser, "/get-access-token", %{provider_id: "github"})
      assert "refreshed-" <> _ = json(conn)["access_token"]
    end

    test "account-info returns the provider's profile", %{browser: browser} do
      {browser, _conn} = sign_in_with_github(browser)
      {browser, conn} = get(browser, "/list-accounts")
      [%{"id" => account_id}] = json(conn)

      {_browser, conn} = get(browser, "/account-info", %{account_id: account_id})
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert json(conn)["data"]["login"] == "ada"
    end
  end

  describe "with strict settings" do
    @describetag auth: Authmk.SocialTest.StrictAuth

    test "sign-up through the provider can be turned off", %{browser: browser} do
      {_browser, conn} = sign_in_with_github(browser)
      assert redirected_to(conn) =~ "error=sign_up_disabled"
    end

    test "even trusted providers don't link to an unverified local account", %{browser: browser} do
      {_browser, _user} = sign_up(browser)
      {_browser, conn} = sign_in_with_github(browser)
      assert redirected_to(conn) =~ "error=account_not_linked"
    end

    test "tokens are encrypted at rest, and state lives in the database", %{browser: browser} do
      {_browser, _user} = sign_up(browser)
      verify_emails(Authmk.SocialTest.StrictAuth)

      {browser, url} = start_github(browser)
      assert Repo.aggregate("verifications", :count) == 1
      {_browser, conn} = get(browser, "/callback/github", FakeProvider.approve(url))
      assert redirected_to(conn) == "/dashboard"

      [token] =
        Repo.all(from(a in "accounts", where: a.provider_id == "github", select: a.access_token))

      assert "enc:" <> _ = token
    end
  end

  describe "Google ID token sign-in" do
    setup do
      {jwk, jwks} = FakeProvider.signing_key()
      FakeProvider.stub(Authmk.SocialTest.Provider, jwks: jwks)
      %{jwk: jwk}
    end

    defp claims(overrides \\ %{}) do
      now = System.system_time(:second)

      Map.merge(
        %{
          "iss" => "https://accounts.google.com",
          "aud" => "google-id",
          "sub" => "g-123",
          "email" => "ada@example.com",
          "email_verified" => true,
          "name" => "Ada",
          "iat" => now,
          "exp" => now + 600,
          "nonce" => "n-1"
        },
        overrides
      )
    end

    defp sign_in_with_id_token(browser, token, nonce \\ "n-1") do
      post(browser, "/sign-in/social", %{
        provider: "google",
        id_token: %{token: token, nonce: nonce}
      })
    end

    test "a valid token signs in", %{browser: browser, jwk: jwk} do
      {browser, conn} = sign_in_with_id_token(browser, FakeProvider.id_token(jwk, claims()))
      assert json(conn)["user"]["email"] == "ada@example.com"

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email_verified"] == true
    end

    test "invalid tokens are refused", %{browser: browser, jwk: jwk} do
      {other_jwk, _jwks} = FakeProvider.signing_key()

      for token <- [
            FakeProvider.id_token(jwk, claims(%{"aud" => "someone-else"})),
            FakeProvider.id_token(jwk, claims(%{"iss" => "https://evil.example"})),
            FakeProvider.id_token(jwk, claims(%{"exp" => System.system_time(:second) - 600})),
            FakeProvider.id_token(jwk, claims(%{"nonce" => "other"})),
            FakeProvider.id_token(other_jwk, claims()),
            unsigned(claims())
          ] do
        {_browser, conn} = sign_in_with_id_token(browser, token)
        assert json(conn)["error"]["code"] == "invalid_id_token"
      end

      assert Repo.aggregate("users", :count) == 0
    end

    test "providers without ID token support refuse it", %{browser: browser, jwk: jwk} do
      {_browser, conn} =
        post(browser, "/sign-in/social", %{
          provider: "github",
          id_token: %{token: FakeProvider.id_token(jwk, claims())}
        })

      assert json(conn)["error"]["code"] == "id_token_not_supported"
    end

    # A token claiming `alg: none`, with no signature.
    defp unsigned(claims) do
      header =
        Base.url_encode64(JSON.encode!(%{"alg" => "none", "kid" => "test-key"}), padding: false)

      payload = Base.url_encode64(JSON.encode!(claims), padding: false)
      header <> "." <> payload <> "."
    end
  end
end
