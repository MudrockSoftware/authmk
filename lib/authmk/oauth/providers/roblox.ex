defmodule Authmk.OAuth.Providers.Roblox do
  @moduledoc """
  Sign in with Roblox.

      social_providers: [roblox: [client_id: "...", client_secret: "..."]]

  Create an OAuth 2.0 app at <https://create.roblox.com/dashboard/credentials>
  with the redirect URL `<base_url>/auth/callback/roblox`. Users pick their
  account and confirm consent each time (`prompt: "select_account consent"`)
  unless you set `prompt`.

  Roblox shares no email. Each user gets a stable placeholder,
  `<roblox id>@roblox.placeholder.invalid` (`.invalid` is a reserved domain
  that never receives mail), which never counts as verified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Roblox",
      authorize_url: "https://apis.roblox.com/oauth/v1/authorize",
      token_url: "https://apis.roblox.com/oauth/v1/token",
      userinfo_url: "https://apis.roblox.com/oauth/v1/userinfo",
      scopes: ["openid", "profile"],
      pkce: false
    ]
  end

  @impl true
  def authorize_params(provider) do
    if provider.options[:prompt], do: [], else: [prompt: "select_account consent"]
  end

  @impl true
  def user_info(tokens, provider, ctx),
    do: Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, email} <- placeholder_email(profile["sub"]) do
      {:ok,
       %{
         id: profile["sub"],
         email: email,
         email_verified: false,
         name: profile["nickname"] || profile["preferred_username"],
         image: profile["picture"]
       }}
    end
  end

  defp placeholder_email(id) when is_binary(id) do
    if id =~ ~r/\A[\w-]+\z/,
      do: {:ok, id <> "@roblox.placeholder.invalid"},
      else: {:error, :invalid_subject}
  end

  defp placeholder_email(_id), do: {:error, :no_subject}
end
