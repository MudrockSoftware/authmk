defmodule Authmk.OAuth.Providers.Kick do
  @moduledoc """
  Sign in with Kick.

      social_providers: [kick: [client_id: "...", client_secret: "..."]]

  Create an app in your Kick account settings, under Developer
  (<https://kick.com/settings/developer>), with the redirect URL
  `<base_url>/auth/callback/kick`. Kick doesn't say whether the email is
  verified, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Kick",
      authorize_url: "https://id.kick.com/oauth/authorize",
      token_url: "https://id.kick.com/oauth/token",
      userinfo_url: "https://api.kick.com/public/v1/users",
      scopes: ["user:read"]
    ]
  end

  # Without an id, the endpoint lists only the token's own user.
  @impl true
  def user_info(tokens, provider, ctx) do
    case Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      {:ok, %{"data" => [user | _rest]}} -> {:ok, user}
      {:ok, _no_user} -> {:error, :no_user}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def map_profile(%{"user_id" => id} = profile, _tokens) when is_integer(id) or is_binary(id) do
    {:ok,
     %{
       id: to_string(id),
       email: profile["email"],
       email_verified: false,
       name: profile["name"],
       image: profile["profile_picture"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
