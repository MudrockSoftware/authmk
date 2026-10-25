defmodule Authmk.OAuth.Providers.Line do
  @moduledoc """
  Sign in with LINE (LINE Login v2.1, OpenID Connect).

      social_providers: [line: [client_id: "...", client_secret: "..."]]

  Create a LINE Login channel at <https://developers.line.biz/console/> with
  the callback URL `<base_url>/auth/callback/line`. Its channel ID is the
  client id and its channel secret the client secret. To get the email,
  apply for email permission in the channel settings.

  The profile comes from the ID token, or from the userinfo endpoint when
  there is none. LINE doesn't say whether the email is verified, so it
  never counts as verified.

  ID tokens from web login are signed with the channel secret (HS256).
  Clients may also sign in with a LINE ID token signed with ES256 (the LINE
  SDKs for native apps and LIFF), verified against LINE's public keys.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.{IDToken, Provider}

  @impl true
  def config do
    [
      name: "LINE",
      authorize_url: "https://access.line.me/oauth2/v2.1/authorize",
      token_url: "https://api.line.me/oauth2/v2.1/token",
      userinfo_url: "https://api.line.me/oauth2/v2.1/userinfo",
      issuer: "https://access.line.me",
      jwks_url: "https://api.line.me/oauth2/v2.1/certs",
      scopes: ["openid", "profile", "email"],
      id_token_sign_in: true,
      id_token_algorithms: ["ES256"]
    ]
  end

  # Web login tokens are signed with the channel secret, app tokens with
  # LINE's keys.
  @impl true
  def verify_id_token(ctx, provider, token, nonce, opts) do
    if hmac_signed?(token) and is_binary(provider.client_secret) do
      key = provider.client_secret |> JOSE.JWK.from_oct() |> JOSE.JWK.to_map() |> elem(1)
      IDToken.verify(ctx, provider, token, nonce, [key: key, algorithms: ["HS256"]] ++ opts)
    else
      IDToken.verify(ctx, provider, token, nonce, opts)
    end
  end

  @impl true
  def user_info(%{claims: %{"sub" => _} = claims}, _provider, _ctx), do: {:ok, claims}

  def user_info(tokens, provider, ctx),
    do: Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, user} <- Provider.standard_claims(profile) do
      {:ok, %{user | email_verified: false}}
    end
  end

  defp hmac_signed?(token) do
    match?(%{"alg" => "HS256"}, token |> JOSE.JWS.peek_protected() |> JSON.decode!())
  rescue
    _malformed -> false
  end
end
