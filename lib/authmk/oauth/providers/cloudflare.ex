defmodule Authmk.OAuth.Providers.Cloudflare do
  @moduledoc """
  Sign in with Cloudflare.

      social_providers: [cloudflare: [client_id: "...", client_secret: "..."]]

  Create an OAuth client in the Cloudflare dashboard (Manage Account →
  OAuth clients) with the redirect URI `<base_url>/auth/callback/cloudflare`
  and the `user-details.read` scope. The client authenticates with HTTP
  Basic auth.

  Cloudflare's OpenID userinfo only has the user id, so the profile comes
  from the API's `/user` endpoint. Cloudflare doesn't say whether the email
  is verified, so it never counts as verified. Without a first or last
  name, the email is the name.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Cloudflare",
      authorize_url: "https://dash.cloudflare.com/oauth2/auth",
      token_url: "https://dash.cloudflare.com/oauth2/token",
      userinfo_url: "https://api.cloudflare.com/client/v4/user",
      scopes: ["user-details.read"],
      token_auth: :basic
    ]
  end

  # The API wraps the user: `{"success": true, "result": {...}}`.
  @impl true
  def user_info(tokens, provider, ctx) do
    case Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      {:ok, %{"success" => true, "result" => %{} = user}} -> {:ok, user}
      {:ok, _failed} -> {:error, :cloudflare_api_error}
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
       name: name(profile),
       image: nil
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  defp name(profile) do
    case Enum.reject([profile["first_name"], profile["last_name"]], &(&1 in [nil, ""])) do
      [] -> profile["email"]
      names -> Enum.join(names, " ")
    end
  end
end
