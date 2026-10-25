defmodule Authmk.OAuth.Providers.TikTok do
  @moduledoc """
  Sign in with TikTok.

      social_providers: [tiktok: [client_id: "<client key>", client_secret: "..."]]

  Create an app at <https://developers.tiktok.com/apps>, add Login Kit with
  the redirect URI `<base_url>/auth/callback/tiktok`, and set `client_id` to
  the app's client key. TikTok calls it `client_key`, in the authorization
  URL and in token requests.

  TikTok shares no email. Users get a placeholder address,
  `<open_id>@tiktok.placeholder.invalid`, which can't receive mail and is
  never verified, so it can't be used to link accounts.
  """

  use Authmk.OAuth.Provider

  alias Authmk.Email
  alias Authmk.OAuth.HTTP

  @impl true
  def config do
    [
      name: "TikTok",
      authorize_url: "https://www.tiktok.com/v2/auth/authorize",
      token_url: "https://open.tiktokapis.com/v2/oauth/token/",
      userinfo_url:
        "https://open.tiktokapis.com/v2/user/info/?fields=open_id,avatar_large_url,display_name,username",
      scopes: ["user.info.profile"],
      scope_separator: ",",
      pkce: false
    ]
  end

  @impl true
  def authorize_params(provider), do: [client_id: nil, client_key: provider.client_id]

  @impl true
  def token_request(ctx, provider, form) do
    credentials = [client_key: provider.client_id, client_secret: provider.client_secret]
    HTTP.post_form(ctx, provider.token_url, credentials ++ form)
  end

  @impl true
  def map_profile(%{"data" => %{"user" => %{"open_id" => open_id} = user}}, _tokens)
      when is_binary(open_id) do
    email = user["email"] || "#{open_id}@tiktok.placeholder.invalid"

    if Email.valid?(email) do
      {:ok,
       %{
         id: open_id,
         email: email,
         email_verified: false,
         name: user["display_name"] || user["username"],
         image: user["avatar_large_url"]
       }}
    else
      {:error, :invalid_email}
    end
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
