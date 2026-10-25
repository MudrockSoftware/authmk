defmodule Authmk.Providers.WeChatTest do
  use Authmk.Test.ProviderCase, provider: :wechat, provider_opts: [lang: "en"]

  alias Authmk.Test.FakeProvider

  @profile %{
    "openid" => "wechat-open-id",
    "unionid" => "wechat-union-id",
    "nickname" => "Ada",
    "headimgurl" => "https://thirdwx.qlogo.cn/ada/132",
    "privilege" => []
  }

  @tokens %{
    "access_token" => "access",
    "refresh_token" => "refresh",
    "expires_in" => 7200,
    "openid" => "wechat-open-id",
    "scope" => "snsapi_login"
  }

  # WeChat takes token requests as GETs with `appid` and `secret`, labels
  # its JSON as text, and answers errors with status 200 and an `errcode`.
  defp access_token(conn, tokens) do
    expected = %{
      "appid" => "client-id",
      "secret" => "client-secret",
      "code" => "code:no-pkce",
      "grant_type" => "authorization_code"
    }

    if conn.method == "GET" and conn.query_params == expected,
      do: {200, JSON.encode!(tokens)},
      else: {200, JSON.encode!(%{"errcode" => 40_029, "errmsg" => "invalid code"})}
  end

  # Refreshing needs no secret.
  defp refresh_token(conn) do
    expected = %{
      "appid" => "client-id",
      "grant_type" => "refresh_token",
      "refresh_token" => "refresh"
    }

    if conn.method == "GET" and conn.query_params == expected,
      do: {200, JSON.encode!(%{@tokens | "access_token" => "refreshed"})},
      else: {200, JSON.encode!(%{"errcode" => 40_030, "errmsg" => "invalid refresh_token"})}
  end

  defp routes(profile, tokens \\ @tokens) do
    %{
      "/sns/oauth2/access_token" => &access_token(&1, tokens),
      "/sns/oauth2/refresh_token" => &refresh_token/1,
      "/sns/userinfo" => fn conn ->
        case conn.query_params do
          %{"access_token" => "access", "openid" => "wechat-open-id", "lang" => "zh_CN"} ->
            {200, JSON.encode!(profile)}

          _invalid ->
            {200, JSON.encode!(%{"errcode" => 40_003, "errmsg" => "invalid openid"})}
        end
      end
    }
  end

  defp callback(browser, auth, fake) do
    FakeProvider.stub(auth, fake)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "wechat", callback_url: "/done"})

    {browser, conn} = get(browser, "/callback/wechat", FakeProvider.approve(json(conn)["url"]))
    {browser, redirected_to(conn)}
  end

  test "signs in with appid, keyed to the unionid, with a placeholder email", %{browser: browser} do
    %{url: url, user: user} = sign_in(browser, routes: routes(@profile))

    assert %URI{
             host: "open.weixin.qq.com",
             path: "/connect/qrconnect",
             fragment: "wechat_redirect"
           } =
             URI.parse(url)

    query = URI.decode_query(URI.parse(url).query)
    assert query["appid"] == "client-id"
    refute Map.has_key?(query, "client_id")
    refute Map.has_key?(query, "code_challenge")
    assert query["scope"] == "snsapi_login"
    assert query["lang"] == "en"

    assert user["email"] == "wechat-union-id@wechat.placeholder.invalid"
    assert user["email_verified"] == false
    assert user["name"] == "Ada"
    assert user["image"] == "https://thirdwx.qlogo.cn/ada/132"
  end

  test "without a unionid, the openid identifies the user", %{browser: browser} do
    %{user: user} = sign_in(browser, routes: routes(Map.delete(@profile, "unionid")))

    assert user["email"] == "wechat-open-id@wechat.placeholder.invalid"
  end

  test "a WeChat error in place of tokens fails the sign-in", %{browser: browser, auth: auth} do
    routes =
      Map.put(routes(@profile), "/sns/oauth2/access_token", fn _conn ->
        {200, ~s({"errcode":40029})}
      end)

    {_browser, location} = callback(browser, auth, routes: routes)

    assert location =~ "error=invalid_code"
  end

  test "tokens without an openid fail the sign-in", %{browser: browser, auth: auth} do
    {_browser, location} =
      callback(browser, auth, routes: routes(@profile, Map.delete(@tokens, "openid")))

    assert location =~ "error=unable_to_get_user_info"
  end

  test "refreshes tokens with a GET and no secret", %{browser: browser, auth: auth} do
    {browser, "/done"} = callback(browser, auth, routes: routes(@profile))

    {_browser, conn} = post(browser, "/refresh-token", %{provider_id: "wechat"})
    assert json(conn)["access_token"] == "refreshed"
  end
end
