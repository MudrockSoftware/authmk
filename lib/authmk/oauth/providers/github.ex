defmodule Authmk.OAuth.Providers.GitHub do
  @moduledoc """
  Sign in with GitHub.

      social_providers: [github: [client_id: "...", client_secret: "..."]]

  Create an OAuth app at <https://github.com/settings/developers> with the
  callback URL `<base_url>/auth/callback/github`. The email comes from
  `/user/emails` (the primary one), with GitHub's verified flag.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @api "https://api.github.com"

  @impl true
  def config do
    [
      name: "GitHub",
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      userinfo_url: @api <> "/user",
      scopes: ["read:user", "user:email"]
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, profile} <- Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      emails =
        case Provider.get_json(ctx, @api <> "/user/emails", tokens.access_token) do
          {:ok, emails} when is_list(emails) -> emails
          _no_access -> []
        end

      {:ok, Map.put(profile, "emails", emails)}
    end
  end

  @impl true
  def map_profile(profile, _tokens) do
    emails = profile["emails"] || []
    email = profile["email"] || primary_email(emails)

    {:ok,
     %{
       id: to_string(profile["id"]),
       email: email,
       email_verified: Enum.any?(emails, &(&1["email"] == email and &1["verified"] == true)),
       name: profile["name"] || profile["login"],
       image: profile["avatar_url"]
     }}
  end

  defp primary_email(emails) do
    primary = Enum.find(emails, & &1["primary"]) || List.first(emails)
    primary && primary["email"]
  end
end
