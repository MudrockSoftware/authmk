defmodule Authmk.OAuth.Providers.Zoom do
  @moduledoc """
  Sign in with Zoom.

      social_providers: [zoom: [client_id: "...", client_secret: "..."]]

  Create a General app at <https://marketplace.zoom.us/> with the redirect
  URL `<base_url>/auth/callback/zoom`, and add the scopes it needs (like
  `user:read:user`) there. The email counts as verified when Zoom marks the
  user as verified. Set `pkce: false` to turn PKCE off.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Zoom",
      authorize_url: "https://zoom.us/oauth/authorize",
      token_url: "https://zoom.us/oauth/token",
      userinfo_url: "https://api.zoom.us/v2/users/me"
    ]
  end

  @impl true
  def options_schema do
    [pkce: [type: :boolean, default: true, doc: "Zoom: send a PKCE challenge."]]
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) do
    {:ok,
     %{
       id: to_string(id),
       email: profile["email"],
       email_verified: profile["verified"] in [1, true],
       name: profile["display_name"],
       image: profile["pic_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
