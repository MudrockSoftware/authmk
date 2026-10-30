defmodule Authmk.OneTapTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [google: [client_id: "google-id", client_secret: "client-secret"]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor,
         skip_verification_on_enable: true, allow_passwordless: true, two_factor_page: "/2fa"},
        {Authmk.Plugins.OneTap, redirect_url: "/dashboard", error_url: "/sign-in"},
        Authmk.Plugins.LastSignInMethod
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  setup do
    {jwk, jwks} = FakeProvider.signing_key()
    FakeProvider.stub(Auth, jwks: jwks)
    %{jwk: jwk}
  end

  defp credential(jwk, overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://accounts.google.com",
          "aud" => "google-id",
          "sub" => "g-1",
          "email" => "ada@example.com",
          "email_verified" => true,
          "name" => "Ada",
          "iat" => now,
          "exp" => now + 600
        },
        overrides
      )

    FakeProvider.id_token(jwk, claims)
  end

  # Google's form post in redirect mode, with its double-submit token.
  defp google_post(browser, credential, csrf \\ "csrf-123", field \\ "csrf-123") do
    browser = %{browser | origin: "https://accounts.google.com"}
    browser = %{browser | cookies: Map.put(browser.cookies, "g_csrf_token", csrf)}
    post(browser, "/one-tap/redirect", %{credential: credential, g_csrf_token: field})
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  describe "JavaScript mode" do
    test "signs in with Google's credential", %{browser: browser, jwk: jwk} do
      {browser, conn} = post(browser, "/one-tap/callback", %{id_token: credential(jwk)})
      assert json(conn)["user"]["email"] == "ada@example.com"
      assert signed_in_user(browser)["email_verified"] == true
    end

    test "refuses tokens not for this app, or not from Google", %{browser: browser, jwk: jwk} do
      {other_key, _jwks} = FakeProvider.signing_key()

      for token <- [
            credential(jwk, %{"aud" => "someone-else"}),
            credential(jwk, %{"iss" => "https://evil.example"}),
            credential(other_key)
          ] do
        {_browser, conn} = post(browser, "/one-tap/callback", %{id_token: token})
        assert json(conn)["error"]["code"] == "invalid_id_token"
      end

      assert Repo.aggregate("users", :count) == 0
    end

    test "is checked for its origin like any other POST", %{browser: browser, jwk: jwk} do
      browser = %{browser | origin: "https://evil.example"}
      {_browser, conn} = post(browser, "/one-tap/callback", %{id_token: credential(jwk)})
      assert json(conn)["error"]["code"] == "invalid_origin"
    end
  end

  describe "redirect mode" do
    test "Google's post signs in and redirects", %{browser: browser, jwk: jwk} do
      {browser, conn} = google_post(browser, credential(jwk))
      assert redirected_to(conn) == "/dashboard"
      assert signed_in_user(browser)["email"] == "ada@example.com"
      assert cookie(browser, "authmk.last_sign_in_method") == "google"
    end

    test "needs Google's double-submit token", %{browser: browser, jwk: jwk} do
      for {cookie, field} <- [{"csrf-123", "other"}, {"", ""}, {"csrf-123", nil}] do
        {browser, conn} = google_post(browser, credential(jwk), cookie, field)
        assert redirected_to(conn) == "/sign-in?error=invalid_origin"
        assert signed_in_user(browser) == nil
      end
    end

    test "only Google may post it", %{browser: browser, jwk: jwk} do
      browser = %{browser | origin: "https://evil.example", cookies: %{"g_csrf_token" => "x"}}

      {_browser, conn} =
        post(browser, "/one-tap/redirect", %{credential: credential(jwk), g_csrf_token: "x"})

      assert redirected_to(conn) == "/sign-in?error=invalid_origin"
    end

    test "a bad credential goes to the error URL", %{browser: browser, jwk: jwk} do
      {_browser, conn} = google_post(browser, credential(jwk, %{"aud" => "someone-else"}))
      assert redirected_to(conn) == "/sign-in?error=invalid_id_token"
    end

    test "users with 2FA go to the 2FA page", %{browser: browser, jwk: jwk} do
      {browser, _conn} = post(browser, "/one-tap/callback", %{id_token: credential(jwk)})
      # No password: a fresh session turns 2FA on.
      {browser, conn} = post(browser, "/two-factor/enable")
      assert json(conn)["totp_uri"]
      {browser, _conn} = post(browser, "/sign-out")

      {browser, conn} = google_post(browser, credential(jwk))
      assert redirected_to(conn) == "/2fa"
      assert signed_in_user(browser) == nil
    end
  end
end
