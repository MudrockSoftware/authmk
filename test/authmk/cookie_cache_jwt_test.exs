defmodule Authmk.CookieCacheJWTTest do
  # The cookie cache as a JWT: HS256 with a key from the secret, or signed
  # with the JWT plugin's keys and checked against its JWKS.
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  defmodule SecretAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      plugins: [Authmk.Plugins.EmailPassword],
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      session: [cookie_cache: [enabled: true, strategy: :jwt]]
  end

  defmodule JWKSAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.JWT],
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      session: [cookie_cache: [enabled: true, strategy: :jwt_jwks]]
  end

  defp cache_cookie(browser),
    do: Enum.find_value(browser.cookies, fn {name, value} -> name =~ "session_data" and value end)

  defp with_cache(browser, value) do
    {name, _value} = Enum.find(browser.cookies, fn {name, _} -> name =~ "session_data" end)
    %{browser | cookies: Map.put(browser.cookies, name, value)}
  end

  describe "HS256 with the secret" do
    @describetag auth: SecretAuth

    test "the cache is a JWT, read without the database", %{browser: browser} do
      {browser, user} = sign_up(browser)
      jwt = cache_cookie(browser)

      # The kid names the secret's version (one unversioned secret is v0).
      assert %JOSE.JWS{alg: {_hmac, :HS256}, fields: %{"kid" => "v0", "typ" => "JWT"}} =
               JOSE.JWT.peek_protected(jwt)

      claims = JOSE.JWT.peek_payload(jwt).fields
      assert claims["sub"] == user["id"]
      assert claims["user"]["email"] == "ada@example.com"
      assert claims["exp"] > System.system_time(:second)

      Repo.delete_all("sessions")
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"
    end

    test "forged tokens are ignored: another key, or no signature", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      claims = JOSE.JWT.peek_payload(cache_cookie(browser)).fields
      Repo.delete_all("sessions")

      other_key = JOSE.JWK.from_oct(:crypto.strong_rand_bytes(32))

      {_jws, forged} =
        other_key
        |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "v0"}, claims)
        |> JOSE.JWS.compact()

      unsigned =
        Base.url_encode64(~s({"alg":"none","kid":"v0"}), padding: false) <>
          "." <> Base.url_encode64(JSON.encode!(claims), padding: false) <> "."

      for token <- [forged, unsigned] do
        {_browser, conn} = get(with_cache(browser, token), "/get-session")
        assert json(conn) == nil
      end
    end
  end

  describe "signed with the JWT plugin's keys" do
    @describetag auth: JWKSAuth

    test "another service checks the cache against the JWKS", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      jwt = cache_cookie(browser)

      {_browser, conn} = get(Browser.new(JWKSAuth), "/jwks")
      [key] = json(conn)["keys"]
      %JOSE.JWS{alg: {_module, alg}} = JOSE.JWT.peek_protected(jwt)

      assert {true, %JOSE.JWT{fields: %{"user" => %{"email" => "ada@example.com"}}}, _jws} =
               JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), [Atom.to_string(alg)], jwt)

      Repo.delete_all("sessions")
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"

      # Changed claims don't verify: the database decides, and signs out.
      [header, _payload, signature] = String.split(jwt, ".")
      claims = JOSE.JWT.peek_payload(jwt).fields |> put_in(["user", "email"], "eve@example.com")

      tampered =
        Enum.join(
          [header, Base.url_encode64(JSON.encode!(claims), padding: false), signature],
          "."
        )

      {_browser, conn} = get(with_cache(browser, tampered), "/get-session")
      assert json(conn) == nil
    end
  end
end
