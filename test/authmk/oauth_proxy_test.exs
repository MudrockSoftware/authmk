defmodule Authmk.OAuthProxyTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.OAuthProxy
  alias Authmk.Test.{Browser, FakeProvider, Repo}

  @secret "a shared secret for every deployment, 32+ bytes"
  @production_callback "https://app.example.com/auth/callback/github"

  defmodule Production do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "https://app.example.com",
      trusted_origins: ["http://localhost:4000"],
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [github: [client_id: "client-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        {Authmk.Plugins.OAuthProxy,
         production_url: "https://app.example.com",
         secret: "a shared secret for every deployment, 32+ bytes"}
      ]
  end

  defmodule Preview do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [github: [client_id: "client-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.OAuthProxy,
         production_url: &__MODULE__.proxy_url/0, secret: &__MODULE__.proxy_secret/0}
      ]

    # Read when the auth module starts, as from runtime config.
    def proxy_url, do: "https://app.example.com/"
    def proxy_secret, do: "a shared secret for every deployment, 32+ bytes"
  end

  @moduletag auth: Preview

  # Both deployments, here on one database (the preview's).
  setup %{auth: auth} do
    start_supervised!(if auth == Preview, do: Production, else: Preview)

    FakeProvider.stub(Preview,
      redirect_uri: @production_callback,
      routes: %{
        "/user" => %{"id" => 1, "login" => "ada", "name" => "Ada", "email" => "ada@example.com"},
        "/user/emails" => [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]
      }
    )

    :ok
  end

  defp query(url), do: URI.decode_query(URI.parse(url).query)

  # The preview starts a sign-in; returns its browser and the provider's URL.
  defp start(browser) do
    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "github", callback_url: "/done"})

    {browser, json(conn)["url"]}
  end

  # Production receives the provider's callback.
  defp at_production(params),
    do: get(Browser.new(Production), "/callback/github", params)

  defp wrap(data, opts \\ []),
    do: Plug.Crypto.sign(@secret, "authmk-oauth-proxy", data, opts)

  test "a preview signs in through production's callback", %{browser: browser} do
    {browser, url} = start(browser)
    assert query(url)["redirect_uri"] == @production_callback

    # Production only sends the browser back, with the preview's own state.
    {production, conn} = at_production(FakeProvider.approve(url))
    back = redirected_to(conn)
    assert "http://localhost:4000/auth/callback/github?" <> _ = back
    assert production.cookies == %{}
    assert Repo.aggregate("users", :count) == 0

    # The preview finishes: its state cookie, its code exchange, its session.
    {browser, conn} = get(browser, "/callback/github", query(back))
    assert redirected_to(conn) == "/done"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
  end

  test "linking an account goes through production too", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/link-social", %{provider: "github", callback_url: "/done"})
    url = json(conn)["url"]
    assert query(url)["redirect_uri"] == @production_callback

    {_production, conn} = at_production(FakeProvider.approve(url))
    {browser, conn} = get(browser, "/callback/github", query(redirected_to(conn)))
    assert redirected_to(conn) == "/done"

    {_browser, conn} = get(browser, "/list-accounts")
    assert "github" in Enum.map(json(conn), & &1["provider_id"])
  end

  test "the code is no good in another browser", %{browser: browser} do
    {_browser, url} = start(browser)
    {_production, conn} = at_production(FakeProvider.approve(url))

    {_attacker, conn} = get(Browser.new(Preview), "/callback/github", query(redirected_to(conn)))
    assert redirected_to(conn) =~ "error=state_mismatch"
    assert Repo.aggregate("users", :count) == 0
  end

  test "production only sends codes where a valid wrapped state says", %{browser: browser} do
    {_browser, url} = start(browser)
    %{"code" => code, "state" => wrapped} = FakeProvider.approve(url)
    {:ok, %{"state" => inner}} = Plug.Crypto.verify(@secret, "authmk-oauth-proxy", wrapped)

    old = System.system_time(:second) - 601
    other_secret = Plug.Crypto.sign(String.duplicate("x", 40), "authmk-oauth-proxy", %{})

    for state <- [
          wrap(%{"state" => inner, "to" => "https://evil.example/auth/callback/github"}),
          wrap(%{"state" => inner, "to" => "http://localhost:4000/auth/callback/google"}),
          wrap(%{"state" => inner, "to" => "/auth/callback/github"}),
          wrap(%{"state" => inner, "to" => "http://localhost:4000/auth/callback/github"},
            signed_at: old
          ),
          other_secret,
          inner
        ] do
      {_production, conn} = at_production(%{code: code, state: state})
      # Treated as production's own sign-in, which has no such flow.
      assert redirected_to(conn) =~ "https://app.example.com/auth/error?error=state_",
             inspect(state)
    end
  end

  @tag auth: Production
  test "sign-ins on production itself aren't proxied", %{browser: browser} do
    {_browser, conn} =
      post(%{browser | origin: "https://app.example.com"}, "/sign-in/social", %{
        provider: "github"
      })

    state = query(json(conn)["url"])["state"]
    assert query(json(conn)["url"])["redirect_uri"] == @production_callback
    assert {:error, _} = Plug.Crypto.verify(@secret, "authmk-oauth-proxy", state)
  end

  test "the secret must be long enough, and the URL absolute" do
    assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
      OAuthProxy.init(production_url: "https://app.example.com", secret: "short")
    end

    assert_raise ArgumentError, ~r/http\(s\) URL/, fn ->
      OAuthProxy.init(production_url: "app.example.com", secret: @secret)
    end
  end
end
