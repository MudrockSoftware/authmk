defmodule Authmk.OAuth.Providers.Paybin do
  @moduledoc """
  Sign in with Paybin (OpenID Connect).

      social_providers: [paybin: [client_id: "...", client_secret: "..."]]

  Register an OAuth client with Paybin with the redirect URI
  `<base_url>/auth/callback/paybin`. The client secret is required. The
  profile comes from the ID token, with Paybin's `email_verified` claim.

  For a Paybin server other than `https://idp.paybin.io`, set `issuer:` to
  its URL.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @issuer "https://idp.paybin.io"

  @impl true
  def config do
    [
      name: "Paybin",
      scopes: ["openid", "email", "profile"]
    ]
  end

  @impl true
  def endpoints(options) do
    issuer = if is_binary(options[:issuer]), do: options[:issuer], else: @issuer
    base = String.trim_trailing(issuer, "/")
    [authorize_url: base <> "/oauth2/authorize", token_url: base <> "/oauth2/token"]
  end

  @impl true
  def options_schema, do: [client_secret: [type: :string, required: true]]

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, user} <- Provider.standard_claims(profile) do
      {:ok, %{user | name: user.name || profile["preferred_username"]}}
    end
  end
end
