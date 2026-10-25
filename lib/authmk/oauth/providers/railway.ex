defmodule Authmk.OAuth.Providers.Railway do
  @moduledoc """
  Sign in with Railway.

      social_providers: [railway: [client_id: "...", client_secret: "..."]]

  Create an OAuth app in your Railway workspace settings (Developer) with
  the redirect URI `<base_url>/auth/callback/railway`. Railway doesn't say
  whether the email is verified, so it never counts as verified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Railway",
      authorize_url: "https://backboard.railway.com/oauth/auth",
      token_url: "https://backboard.railway.com/oauth/token",
      userinfo_url: "https://backboard.railway.com/oauth/me",
      scopes: ["openid", "email", "profile"],
      token_auth: :basic
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx),
    do: Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, user} <- Provider.standard_claims(profile) do
      {:ok, %{user | email_verified: false}}
    end
  end
end
