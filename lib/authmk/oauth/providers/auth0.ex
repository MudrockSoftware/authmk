defmodule Authmk.OAuth.Providers.Auth0 do
  @moduledoc """
  Sign in with Auth0 (OpenID Connect).

      social_providers: [auth0: [domain: "acme.us.auth0.com", client_id: "...", client_secret: "..."]]

  Create a Regular Web Application in the Auth0 dashboard with the allowed
  callback URL `<base_url>/auth/callback/auth0`. `domain` is the tenant's
  domain (or a custom domain); the endpoints and keys come from its
  discovery document. Clients may also sign in with an Auth0 ID token.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Discovery

  @impl true
  def config, do: [name: "Auth0", scopes: ["openid", "email", "profile"], id_token_sign_in: true]

  @impl true
  def options_schema,
    do: [domain: [type: :string, required: true, doc: "Auth0: the tenant's domain."]]

  @impl true
  def endpoints(options) do
    issuer = "https://" <> String.replace_prefix(options[:domain], "https://", "")
    [discovery_url: Discovery.url(issuer)]
  end
end
