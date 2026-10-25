defmodule Authmk.OAuth.Providers.Notion do
  @moduledoc """
  Sign in with Notion.

      social_providers: [notion: [client_id: "...", client_secret: "..."]]

  Create a public integration at <https://www.notion.so/profile/integrations>
  with the redirect URI `<base_url>/auth/callback/notion`, and enable "Read
  user information including email addresses". The user is the workspace
  member who installs the integration. Notion doesn't say whether the email
  is verified, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.HTTP

  @notion_version "2022-06-28"

  @impl true
  def config do
    [
      name: "Notion",
      authorize_url: "https://api.notion.com/v1/oauth/authorize",
      token_url: "https://api.notion.com/v1/oauth/token",
      userinfo_url: "https://api.notion.com/v1/users/me",
      scopes: [],
      pkce: false,
      token_auth: :basic
    ]
  end

  @impl true
  def authorize_params(_provider), do: [owner: "user"]

  # The token belongs to a bot; the user is the person who installed it.
  @impl true
  def user_info(tokens, provider, ctx) do
    headers = [
      {"authorization", "Bearer " <> tokens.access_token},
      {"notion-version", @notion_version}
    ]

    case HTTP.get(ctx, provider.userinfo_url, headers) do
      {:ok, 200, %{"bot" => %{"owner" => %{"user" => %{} = user}}}} -> {:ok, user}
      {:ok, 200, _no_user} -> {:error, :no_user}
      {:ok, status, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: get_in(profile, ["person", "email"]),
       email_verified: false,
       name: profile["name"],
       image: profile["avatar_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
