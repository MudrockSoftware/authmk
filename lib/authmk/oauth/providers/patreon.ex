defmodule Authmk.OAuth.Providers.Patreon do
  @moduledoc """
  Sign in with Patreon.

      social_providers: [patreon: [client_id: "...", client_secret: "..."]]

  Register a client at <https://www.patreon.com/portal/registration/register-clients>
  with the redirect URI `<base_url>/auth/callback/patreon`. The email counts
  as verified only when Patreon says so.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider
  alias Authmk.URL

  @impl true
  def config do
    [
      name: "Patreon",
      authorize_url: "https://www.patreon.com/oauth2/authorize",
      token_url: "https://www.patreon.com/api/oauth2/token",
      userinfo_url: "https://www.patreon.com/api/oauth2/v2/identity",
      scopes: ["identity", "identity[email]"],
      pkce: false
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    url =
      URL.append_query(provider.userinfo_url, [
        {:"fields[user]", "email,full_name,image_url,is_email_verified"}
      ])

    case Provider.get_json(ctx, url, tokens.access_token) do
      {:ok, %{"data" => %{"id" => _} = user}} -> {:ok, user}
      _failed -> {:error, :no_user_info}
    end
  end

  @impl true
  def map_profile(%{"id" => id} = user, _tokens) when is_binary(id) do
    attributes = user["attributes"] || %{}

    {:ok,
     %{
       id: id,
       email: attributes["email"],
       email_verified: attributes["is_email_verified"] == true,
       name: attributes["full_name"],
       image: attributes["image_url"]
     }}
  end

  def map_profile(_user, _tokens), do: {:error, :no_user_id}
end
