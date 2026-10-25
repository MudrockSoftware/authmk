defmodule Authmk.OAuth.Providers.WeChat do
  @moduledoc """
  Sign in with WeChat (Website Application, QR code login).

      social_providers: [wechat: [client_id: "<AppID>", client_secret: "<AppSecret>", lang: "en"]]

  Create a Website Application at <https://open.weixin.qq.com/> and set its
  authorization callback domain to your app's host; the callback URL is
  `<base_url>/auth/callback/wechat`. `client_id` is the AppID and
  `client_secret` the AppSecret. `lang` is the login page's language,
  `"cn"` (default) or `"en"`.

  WeChat names its parameters differently (`appid`, `secret`), takes token
  requests as GETs, and returns the user's `openid` with the tokens. Users
  are identified by their `unionid` (the same across a developer's apps)
  when WeChat sends one, otherwise by their `openid`.

  WeChat shares no email. Users get a placeholder address,
  `<unionid or openid>@wechat.placeholder.invalid`, which can't receive mail
  and is never verified, so it can't be used to link accounts.
  """

  use Authmk.OAuth.Provider

  alias Authmk.{Email, URL}
  alias Authmk.OAuth.HTTP

  @refresh_url "https://api.weixin.qq.com/sns/oauth2/refresh_token"

  @impl true
  def config do
    [
      name: "WeChat",
      authorize_url: "https://open.weixin.qq.com/connect/qrconnect#wechat_redirect",
      token_url: "https://api.weixin.qq.com/sns/oauth2/access_token",
      userinfo_url: "https://api.weixin.qq.com/sns/userinfo",
      scopes: ["snsapi_login"],
      scope_separator: ",",
      pkce: false
    ]
  end

  @impl true
  def options_schema do
    [lang: [type: {:in, ["cn", "en"]}, default: "cn", doc: "WeChat: login page language."]]
  end

  @impl true
  def authorize_params(provider) do
    [client_id: nil, appid: provider.client_id, lang: provider.options[:lang]]
  end

  @impl true
  def token_request(ctx, provider, form) do
    url =
      case form[:grant_type] do
        "authorization_code" ->
          URL.append_query(provider.token_url,
            appid: provider.client_id,
            secret: provider.client_secret,
            code: form[:code],
            grant_type: "authorization_code"
          )

        "refresh_token" ->
          URL.append_query(@refresh_url,
            appid: provider.client_id,
            grant_type: "refresh_token",
            refresh_token: form[:refresh_token]
          )
      end

    get_json(ctx, url)
  end

  # The profile needs the openid that came with the tokens.
  @impl true
  def user_info(tokens, provider, ctx) do
    case tokens.raw["openid"] do
      openid when is_binary(openid) ->
        query = [access_token: tokens.access_token, openid: openid, lang: "zh_CN"]

        case get_json(ctx, URL.append_query(provider.userinfo_url, query)) do
          {:ok, 200, %{"openid" => _} = profile} -> {:ok, profile}
          _error -> {:error, :no_user_info}
        end

      _missing ->
        {:error, :no_openid}
    end
  end

  @impl true
  def map_profile(%{"openid" => openid} = profile, _tokens) do
    id = profile["unionid"] || openid
    email = profile["email"] || "#{id}@wechat.placeholder.invalid"

    if Email.valid?(email) do
      {:ok,
       %{
         id: id,
         email: email,
         email_verified: false,
         name: profile["nickname"],
         image: profile["headimgurl"]
       }}
    else
      {:error, :invalid_email}
    end
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  # WeChat may label its JSON as text, and reports errors with status 200
  # and an `errcode`, which callers reject because the expected keys are
  # missing.
  defp get_json(ctx, url) do
    case HTTP.get(ctx, url) do
      {:ok, status, body} when is_binary(body) -> {:ok, status, decode(body)}
      response -> response
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> json
      {:error, _reason} -> body
    end
  end
end
