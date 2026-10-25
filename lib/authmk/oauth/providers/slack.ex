defmodule Authmk.OAuth.Providers.Slack do
  @moduledoc """
  Sign in with Slack (OpenID Connect).

      social_providers: [slack: [client_id: "...", client_secret: "..."]]

  Create an app at <https://api.slack.com/apps>, and under "OAuth &
  Permissions" add the redirect URL `<base_url>/auth/callback/slack` and the
  `openid`, `profile` and `email` user scopes. Slack doesn't support PKCE
  here, so none is sent. Accounts are keyed by the Slack user id.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Slack",
      authorize_url: "https://slack.com/openid/connect/authorize",
      token_url: "https://slack.com/api/openid.connect.token",
      userinfo_url: "https://slack.com/api/openid.connect.userInfo",
      scopes: ["openid", "profile", "email"],
      pkce: false
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)
  end

  # Slack answers errors with 200 and `"ok": false`, without a user id.
  @impl true
  def map_profile(%{"https://slack.com/user_id" => user_id} = profile, _tokens)
      when is_binary(user_id) do
    {:ok,
     %{
       id: user_id,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["name"],
       image: profile["picture"] || profile["https://slack.com/user_image_512"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
