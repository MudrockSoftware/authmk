defmodule Authmk.OAuth.Providers.Gumroad do
  @moduledoc """
  Sign in with Gumroad.

      social_providers: [gumroad: [client_id: "...", client_secret: "..."]]

  Create an application at <https://gumroad.com/settings/advanced> with the
  redirect URI `<base_url>/auth/callback/gumroad`. Gumroad doesn't say
  whether the email is verified, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Gumroad",
      authorize_url: "https://gumroad.com/oauth/authorize",
      token_url: "https://api.gumroad.com/oauth/token",
      userinfo_url: "https://api.gumroad.com/v2/user",
      scopes: ["view_profile"],
      pkce: false
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    case Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      {:ok, %{"success" => true, "user" => %{} = user}} -> {:ok, user}
      _failed -> {:error, :no_user_info}
    end
  end

  @impl true
  def map_profile(%{"user_id" => user_id} = user, _tokens) when is_binary(user_id) do
    {:ok,
     %{
       id: user_id,
       email: user["email"],
       email_verified: false,
       name: user["name"],
       image: user["profile_url"]
     }}
  end

  def map_profile(_user, _tokens), do: {:error, :no_user_id}
end
