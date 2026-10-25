defmodule Authmk.OAuth.Providers.Twitch do
  @moduledoc """
  Sign in with Twitch (OpenID Connect).

      social_providers: [twitch: [client_id: "...", client_secret: "..."]]

  Register an application at <https://dev.twitch.tv/console/apps> with the
  OAuth redirect URL `<base_url>/auth/callback/twitch`. The profile comes
  from the ID token's claims (verified against Twitch's keys), with Twitch's
  `email_verified`. Twitch puts
  only the claims you ask for in the ID token: `claims:` replaces the
  default extra claims (`preferred_username` and `picture`); `email` and
  `email_verified` are always requested.
  """

  use Authmk.OAuth.Provider

  @default_claims ["email", "email_verified", "preferred_username", "picture"]

  @impl true
  def config do
    [
      name: "Twitch",
      authorize_url: "https://id.twitch.tv/oauth2/authorize",
      token_url: "https://id.twitch.tv/oauth2/token",
      issuer: "https://id.twitch.tv/oauth2",
      jwks_url: "https://id.twitch.tv/oauth2/keys",
      scopes: ["user:read:email", "openid"],
      pkce: false
    ]
  end

  @impl true
  def options_schema do
    [claims: [type: {:list, :string}, doc: "Twitch: ID token claims to request."]]
  end

  @impl true
  def authorize_params(provider) do
    claims = ["email", "email_verified"] ++ (provider.options[:claims] || @default_claims)
    [claims: JSON.encode!(%{"id_token" => Map.new(claims, &{&1, nil})})]
  end

  @impl true
  def map_profile(%{"sub" => sub} = claims, _tokens) do
    {:ok,
     %{
       id: to_string(sub),
       email: claims["email"],
       email_verified: claims["email_verified"] == true,
       name: claims["preferred_username"],
       image: claims["picture"]
     }}
  end

  def map_profile(_claims, _tokens), do: {:error, :no_subject}
end
