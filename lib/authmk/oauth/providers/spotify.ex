defmodule Authmk.OAuth.Providers.Spotify do
  @moduledoc """
  Sign in with Spotify.

      social_providers: [spotify: [client_id: "...", client_secret: "..."]]

  Create an app at <https://developer.spotify.com/dashboard> with the
  redirect URI `<base_url>/auth/callback/spotify`. Spotify doesn't say
  whether it verified the email, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Spotify",
      authorize_url: "https://accounts.spotify.com/authorize",
      token_url: "https://accounts.spotify.com/api/token",
      userinfo_url: "https://api.spotify.com/v1/me",
      scopes: ["user-read-email"]
    ]
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) do
    {:ok,
     %{
       id: to_string(id),
       email: profile["email"],
       email_verified: false,
       name: profile["display_name"],
       image: first_image(profile["images"])
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  defp first_image([%{"url" => url} | _rest]), do: url
  defp first_image(_no_images), do: nil
end
