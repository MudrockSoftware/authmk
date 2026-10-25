defmodule Authmk.OAuth.Providers.Figma do
  @moduledoc """
  Sign in with Figma.

      social_providers: [figma: [client_id: "...", client_secret: "..."]]

  Create an app at <https://www.figma.com/developers/apps> with the callback
  URL `<base_url>/auth/callback/figma`. The client secret is required. Figma
  doesn't say whether the email is verified, so it counts as unverified.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Figma",
      authorize_url: "https://www.figma.com/oauth",
      token_url: "https://api.figma.com/v1/oauth/token",
      userinfo_url: "https://api.figma.com/v1/me",
      scopes: ["current_user:read"],
      token_auth: :basic
    ]
  end

  @impl true
  def options_schema, do: [client_secret: [type: :string, required: true]]

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: profile["email"],
       email_verified: false,
       name: profile["handle"],
       image: profile["img_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
