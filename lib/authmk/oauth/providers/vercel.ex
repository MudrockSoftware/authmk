defmodule Authmk.OAuth.Providers.Vercel do
  @moduledoc """
  Sign in with Vercel.

      social_providers: [vercel: [client_id: "...", client_secret: "...", scopes: ["openid", "email", "profile"]]]

  Create an integration at <https://vercel.com/dashboard/integrations/console>
  with the callback URL `<base_url>/auth/callback/vercel`. Vercel requests no
  scopes by default; list the ones you need in `scopes:`. Sign-in always
  uses PKCE. Public clients may leave out `client_secret`.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Vercel",
      authorize_url: "https://vercel.com/oauth/authorize",
      token_url: "https://api.vercel.com/login/oauth/token",
      userinfo_url: "https://api.vercel.com/login/oauth/userinfo"
    ]
  end

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, user} <- Provider.standard_claims(profile) do
      {:ok, %{user | name: profile["name"] || profile["preferred_username"]}}
    end
  end
end
