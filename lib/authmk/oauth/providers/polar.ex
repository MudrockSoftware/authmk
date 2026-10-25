defmodule Authmk.OAuth.Providers.Polar do
  @moduledoc """
  Sign in with Polar.

      social_providers: [polar: [client_id: "...", client_secret: "..."]]

  Create an OAuth 2.0 client in Polar's settings (Developers) with the
  redirect URI `<base_url>/auth/callback/polar`. The email counts as
  verified only when Polar says so.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Polar",
      authorize_url: "https://polar.sh/oauth2/authorize",
      token_url: "https://api.polar.sh/v1/oauth2/token",
      userinfo_url: "https://api.polar.sh/v1/oauth2/userinfo",
      scopes: ["openid", "profile", "email"]
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx),
    do: Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) do
    {:ok,
     %{
       id: to_string(id),
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["public_name"] || profile["username"],
       image: profile["avatar_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_subject}
end
