defmodule Authmk.OAuth.Providers.Okta do
  @moduledoc """
  Sign in with Okta (OpenID Connect).

      social_providers: [
        okta: [
          issuer: "https://acme.okta.com/oauth2/default",
          client_id: "...",
          client_secret: "..."
        ]
      ]

  Create an OIDC Web Application in the Okta admin console with the
  sign-in redirect URI `<base_url>/auth/callback/okta`. The issuer is the
  authorization server's URL (`https://<org>.okta.com/oauth2/default`, or
  `https://<org>.okta.com` for the org server); the endpoints and keys come
  from its discovery document. Clients may also sign in with an Okta ID
  token.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Discovery

  @impl true
  def config, do: [name: "Okta", scopes: ["openid", "email", "profile"], id_token_sign_in: true]

  @impl true
  def options_schema,
    do: [issuer: [type: :string, required: true, doc: "Okta: the authorization server URL."]]

  @impl true
  def endpoints(options), do: [discovery_url: Discovery.url(options[:issuer])]
end
