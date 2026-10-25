defmodule Authmk.OAuth.Providers.LinkedIn do
  @moduledoc """
  Sign in with LinkedIn (OpenID Connect).

      social_providers: [linkedin: [client_id: "...", client_secret: "..."]]

  Create an app at <https://www.linkedin.com/developers/apps>, add the
  "Sign In with LinkedIn using OpenID Connect" product, and add the
  redirect URL `<base_url>/auth/callback/linkedin`. LinkedIn doesn't support
  PKCE for web apps, so none is sent. The email counts as verified only when
  LinkedIn says so.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "LinkedIn",
      authorize_url: "https://www.linkedin.com/oauth/v2/authorization",
      token_url: "https://www.linkedin.com/oauth/v2/accessToken",
      userinfo_url: "https://api.linkedin.com/v2/userinfo",
      scopes: ["profile", "email", "openid"],
      pkce: false
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)
  end
end
