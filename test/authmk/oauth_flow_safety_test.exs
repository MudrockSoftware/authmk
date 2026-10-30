defmodule Authmk.OAuthFlowSafetyTest do
  # Every built-in provider's sign-in carries a state bound to this browser,
  # and a PKCE challenge unless the provider can't take one. A callback
  # with someone else's state is refused before any code is exchanged.
  use Authmk.EmulationCase, async: true

  alias Authmk.OAuth.Providers
  alias Authmk.Test.Browser

  # Providers that refuse or don't support PKCE: they rely on state, and a
  # client secret, alone. Anything else must send a challenge.
  @without_pkce ~w(discord facebook gumroad hubspot kakao linear linkedin naver notion patreon reddit roblox slack tiktok twitch wechat)a

  @extra %{
    auth0: [domain: "tenant.example.com"],
    okta: [issuer: "https://idp.example.com"],
    keycloak: [issuer: "https://idp.example.com/realms/acme"],
    cognito: [domain: "pool.example.com", region: "eu-west-1", user_pool_id: "eu-west-1_abc"],
    generic: [
      authorize_url: "https://idp.example.com/authorize",
      token_url: "https://idp.example.com/token",
      userinfo_url: "https://idp.example.com/userinfo"
    ]
  }

  @providers (for {name, _module} <- Providers.built_in() do
                {name,
                 [client_id: "client-id", client_secret: "client-secret"] ++
                   Map.get(@extra, name, [])}
              end)

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: Module.get_attribute(Authmk.OAuthFlowSafetyTest, :providers),
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  # Discovery documents for the OpenID Connect providers; any other
  # request is recorded and answered with an error.
  setup do
    test = self()

    Req.Test.stub(Auth, fn conn ->
      send(test, {:outbound, conn.request_path})

      if String.ends_with?(conn.request_path, "/.well-known/openid-configuration") do
        Req.Test.json(conn, %{
          "issuer" =>
            "https://#{conn.host}" <>
              String.replace_suffix(conn.request_path, "/.well-known/openid-configuration", ""),
          "authorization_endpoint" => "https://#{conn.host}/authorize",
          "token_endpoint" => "https://#{conn.host}/token",
          "userinfo_endpoint" => "https://#{conn.host}/userinfo",
          "jwks_uri" => "https://#{conn.host}/jwks"
        })
      else
        Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    :ok
  end

  test "state on every provider, PKCE on all that take it, forged callbacks refused" do
    for {provider, _module} <- Providers.built_in() do
      {browser, conn} =
        post(Browser.new(Auth), "/sign-in/social", %{provider: provider, callback_url: "/done"})

      url = json(conn)["url"] || flunk("#{provider}: #{inspect(json(conn))}")
      query = URI.decode_query(URI.parse(url).query || "")

      assert byte_size(query["state"] || "") >= 32, "#{provider} sends no state"

      if provider in @without_pkce do
        refute Map.has_key?(query, "code_challenge"),
               "#{provider} sends PKCE: update @without_pkce"
      else
        assert query["code_challenge_method"] == "S256", "#{provider} sends no PKCE"
        assert byte_size(query["code_challenge"]) == 43
      end

      # The provider sends someone back with another state, or none.
      for state <- ["forged-" <> String.duplicate("a", 40), nil] do
        params = if state, do: %{code: "a-code", state: state}, else: %{code: "a-code"}
        {_browser, conn} = get(browser, "/callback/#{provider}", params)
        assert redirected_to(conn) =~ "error=state_", "#{provider} took a forged state"
      end

      refute_received {:outbound, "/token"}
      refute_received {:outbound, "/oauth/token"}
    end
  end
end
