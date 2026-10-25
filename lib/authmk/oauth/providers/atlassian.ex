defmodule Authmk.OAuth.Providers.Atlassian do
  @moduledoc """
  Sign in with Atlassian.

      social_providers: [atlassian: [client_id: "...", client_secret: "..."]]

  Create an OAuth 2.0 (3LO) app at
  <https://developer.atlassian.com/console/myapps/> with the callback URL
  `<base_url>/auth/callback/atlassian`, and grant it the User identity API
  and Jira's `read:jira-user` scope. Atlassian doesn't say whether the email
  is verified, so it never counts as verified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Atlassian",
      authorize_url: "https://auth.atlassian.com/authorize",
      token_url: "https://auth.atlassian.com/oauth/token",
      userinfo_url: "https://api.atlassian.com/me",
      scopes: ["read:jira-user", "offline_access"]
    ]
  end

  @impl true
  def authorize_params(_provider), do: [audience: "api.atlassian.com"]

  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)
  end

  @impl true
  def map_profile(%{"account_id" => account_id} = profile, _tokens) when is_binary(account_id) do
    {:ok,
     %{
       id: account_id,
       email: profile["email"],
       email_verified: false,
       name: profile["name"],
       image: profile["picture"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_account_id}
end
