defmodule Authmk.OAuth.Providers.Cognito do
  @moduledoc """
  Sign in with an Amazon Cognito user pool (OpenID Connect).

  Every user pool has its own endpoints, from its domain, region and pool id:

      social_providers: [
        cognito: [
          client_id: "...",
          client_secret: "...",
          domain: "<prefix>.auth.<region>.amazoncognito.com",
          region: "us-east-1",
          user_pool_id: "us-east-1_AbCdEf"
        ]
      ]

  The domain may be a custom domain. Explicit `authorize_url:`, `token_url:`,
  `userinfo_url:`, `issuer:` and `jwks_url:` win over the derived ones.

  Create an app client in your user pool at
  <https://console.aws.amazon.com/cognito/v2/idp/user-pools> with the
  callback URL `<base_url>/auth/callback/cognito` and the `openid`, `email`
  and `profile` scopes. Public app clients may leave out `client_secret`.

  Set `identity_provider` (like `"Google"`, `"SignInWithApple"` or a SAML
  provider's name) to skip Cognito's provider picker. The name falls back to
  `given_name`, then `username`. Clients may also sign in with a Cognito ID
  token.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Cognito",
      scopes: ["openid", "profile", "email"],
      id_token_sign_in: true
    ]
  end

  @impl true
  def options_schema do
    [
      domain: [type: :string, required: true, doc: "Cognito: the user pool's domain."],
      region: [type: :string, required: true, doc: "Cognito: the user pool's AWS region."],
      user_pool_id: [type: :string, required: true, doc: "Cognito: the user pool id."],
      identity_provider: [
        type: :string,
        doc: ~s(Preselects an identity provider, like "Google" or "COGNITO".)
      ]
    ]
  end

  @impl true
  def endpoints(options) do
    domain =
      "https://" <>
        (options[:domain] |> String.replace_prefix("https://", "") |> String.trim_trailing("/"))

    issuer = "https://cognito-idp.#{options[:region]}.amazonaws.com/#{options[:user_pool_id]}"

    [
      authorize_url: domain <> "/oauth2/authorize",
      token_url: domain <> "/oauth2/token",
      userinfo_url: domain <> "/oauth2/userinfo",
      issuer: issuer,
      jwks_url: issuer <> "/.well-known/jwks.json"
    ]
  end

  @impl true
  def authorize_params(provider), do: [identity_provider: provider.options[:identity_provider]]

  # Access tokens are signed with the same keys; only ID tokens sign in.
  @impl true
  def validate_claims(%{"token_use" => token_use}, _provider) when token_use != "id",
    do: {:error, :invalid_id_token}

  def validate_claims(_claims, _provider), do: :ok

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, user} <- Provider.standard_claims(profile) do
      {:ok, %{user | name: profile["name"] || profile["given_name"] || profile["username"]}}
    end
  end
end
