defmodule Authmk.OAuth.Providers.Linear do
  @moduledoc """
  Sign in with Linear.

      social_providers: [linear: [client_id: "...", client_secret: "..."]]

  Create an OAuth application in Linear under Settings > API
  (<https://linear.app/settings/api/applications/new>) with the callback URL
  `<base_url>/auth/callback/linear`. Linear doesn't say whether the email is
  verified, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @viewer_query "query { viewer { id name email avatarUrl active createdAt updatedAt } }"

  @impl true
  def config do
    [
      name: "Linear",
      authorize_url: "https://linear.app/oauth/authorize",
      token_url: "https://api.linear.app/oauth/token",
      userinfo_url: "https://api.linear.app/graphql",
      scopes: ["read"],
      pkce: false
    ]
  end

  # Linear's API is GraphQL: the user is the query's `viewer`.
  @impl true
  def user_info(tokens, provider, ctx) do
    case Provider.post_json(ctx, provider.userinfo_url, tokens.access_token, %{
           query: @viewer_query
         }) do
      {:ok, %{"data" => %{"viewer" => %{} = viewer}}} -> {:ok, viewer}
      {:ok, _errors} -> {:error, :no_viewer}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: profile["email"],
       email_verified: false,
       name: profile["name"],
       image: profile["avatarUrl"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
