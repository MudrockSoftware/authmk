defmodule Authmk.OAuth.Providers.Dropbox do
  @moduledoc """
  Sign in with Dropbox.

      social_providers: [dropbox: [client_id: "...", client_secret: "...", access_type: "offline"]]

  Create an app at <https://www.dropbox.com/developers/apps> with the
  `account_info.read` permission and the redirect URI
  `<base_url>/auth/callback/dropbox`. Set `access_type: "offline"` to get a
  refresh token (sent as Dropbox's `token_access_type`). The email comes with
  Dropbox's `email_verified` flag.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Dropbox",
      authorize_url: "https://www.dropbox.com/oauth2/authorize",
      token_url: "https://api.dropboxapi.com/oauth2/token",
      userinfo_url: "https://api.dropboxapi.com/2/users/get_current_account",
      scopes: ["account_info.read"]
    ]
  end

  @impl true
  def authorize_params(provider), do: [token_access_type: provider.options[:access_type]]

  # Dropbox's API takes POSTs; this call has no arguments.
  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.post_json(ctx, provider.userinfo_url, tokens.access_token, nil)
  end

  @impl true
  def map_profile(%{"account_id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: get_in(profile, ["name", "display_name"]),
       image: profile["profile_photo_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
