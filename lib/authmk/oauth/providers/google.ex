defmodule Authmk.OAuth.Providers.Google do
  @moduledoc """
  Sign in with Google (OpenID Connect).

      social_providers: [google: [client_id: "...", client_secret: "...", access_type: "offline"]]

  Create credentials at <https://console.cloud.google.com/apis/credentials>
  with the redirect URI `<base_url>/auth/callback/google`. Set
  `access_type: "offline"` to get a refresh token. Clients may also sign in
  with a Google ID token (One Tap, mobile SDKs).
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Google",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      issuer: ["https://accounts.google.com", "accounts.google.com"],
      jwks_url: "https://www.googleapis.com/oauth2/v3/certs",
      scopes: ["openid", "email", "profile"],
      id_token_sign_in: true
    ]
  end

  @impl true
  def authorize_params(provider) do
    [access_type: provider.options[:access_type], include_granted_scopes: "true"]
  end
end
