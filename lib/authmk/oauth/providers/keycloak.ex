defmodule Authmk.OAuth.Providers.Keycloak do
  @moduledoc """
  Sign in with Keycloak (OpenID Connect).

      social_providers: [
        keycloak: [
          issuer: "https://sso.example.com/realms/acme",
          client_id: "...",
          client_secret: "..."
        ]
      ]

  Create an OpenID Connect client in the realm with client authentication
  on, and the valid redirect URI `<base_url>/auth/callback/keycloak`. The
  issuer is the realm's URL; the endpoints and keys come from its discovery
  document. Clients may also sign in with the realm's ID tokens.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Discovery

  @impl true
  def config,
    do: [name: "Keycloak", scopes: ["openid", "email", "profile"], id_token_sign_in: true]

  @impl true
  def options_schema,
    do: [issuer: [type: :string, required: true, doc: "Keycloak: the realm URL."]]

  @impl true
  def endpoints(options), do: [discovery_url: Discovery.url(options[:issuer])]
end
