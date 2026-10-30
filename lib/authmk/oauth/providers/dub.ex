defmodule Authmk.OAuth.Providers.Dub do
  @moduledoc """
  Link Dub accounts (dub.co), for integrations that act on a user's Dub
  workspace.

      social_providers: [dub: [client_id: "...", client_secret: "..."]]

  Create an OAuth app in Dub's workspace settings with the callback URL
  `<base_url>/auth/callback/dub`, and ask for the scopes your integration
  needs (`scopes:`; `user.read` always). Dub doesn't give the user's email,
  so a Dub account is linked to a signed-in user (`POST /link-social`), and
  after that signs them in; it never creates users.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Dub",
      authorize_url: "https://app.dub.co/oauth/authorize",
      token_url: "https://api.dub.co/oauth/token",
      userinfo_url: "https://api.dub.co/oauth/userinfo",
      scopes: ["user.read"],
      requires_email: false
    ]
  end

  @impl true
  def map_profile(profile, _tokens) do
    {:ok,
     %{
       id: profile["id"],
       email: nil,
       email_verified: false,
       name: profile["name"],
       image: profile["image"]
     }}
  end
end
