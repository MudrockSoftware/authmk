defmodule Authmk.OAuth.Providers.HubSpot do
  @moduledoc """
  Sign in with HubSpot.

      social_providers: [hubspot: [client_id: "...", client_secret: "..."]]

  Create an app in a HubSpot developer account with the redirect URL
  `<base_url>/auth/callback/hubspot` and the `oauth` scope. The user is the
  HubSpot user who installed the app, read from the access token's
  metadata; HubSpot doesn't say whether the email is verified, so it counts
  as unverified. HubSpot has no profile pictures.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.HTTP

  @api "https://api.hubapi.com"

  @impl true
  def config do
    [
      name: "HubSpot",
      authorize_url: "https://app.hubspot.com/oauth/authorize",
      token_url: @api <> "/oauth/v1/token",
      userinfo_url: @api <> "/oauth/v1/access-tokens",
      scopes: ["oauth"],
      pkce: false
    ]
  end

  # The token's metadata names its user: `user` (the email) and `user_id`.
  @impl true
  def user_info(%{access_token: token}, provider, ctx) when is_binary(token) do
    case HTTP.get(ctx, provider.userinfo_url <> "/" <> URI.encode_www_form(token)) do
      {:ok, 200, %{} = info} -> {:ok, info}
      _failed -> {:error, :no_user_info}
    end
  end

  def user_info(_tokens, _provider, _ctx), do: {:error, :no_access_token}

  @impl true
  def map_profile(%{"user_id" => user_id} = info, _tokens) when is_integer(user_id) do
    {:ok,
     %{id: to_string(user_id), email: info["user"], email_verified: false, name: nil, image: nil}}
  end

  def map_profile(_info, _tokens), do: {:error, :no_user_id}
end
