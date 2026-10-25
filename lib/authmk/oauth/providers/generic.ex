defmodule Authmk.OAuth.Providers.Generic do
  @moduledoc """
  Any OpenID Connect or OAuth 2.0 provider, from its issuer or by hand.

  With OpenID Connect, the issuer is enough: its discovery document gives the
  endpoints and keys.

      social_providers: [
        acme: [
          provider: :generic,
          name: "Acme",
          issuer: "https://login.acme.example",
          client_id: "...",
          client_secret: "..."
        ]
      ]

  Set `discovery_url:` when the document isn't at
  `<issuer>/.well-known/openid-configuration`. For plain OAuth 2.0, set the
  endpoints instead, and the scopes the provider wants:

      legacy: [
        provider: :generic,
        authorize_url: "https://legacy.example/oauth/authorize",
        token_url: "https://legacy.example/oauth/token",
        userinfo_url: "https://legacy.example/api/me",
        disable_default_scopes: true,
        scopes: ["profile"],
        profile_map: [id: "uid", email: "mail", email_verified: nil, image: "avatar"]
      ]

  The profile is the ID token's claims merged with the userinfo answer.
  `profile_map:` names the fields that hold the user's id, email, name and
  picture, and whether the email is verified; `nil` leaves one out (an
  email without a verified field counts as unverified). For anything else,
  like a nested profile, use `c:Authmk.map_social_profile/2`, or write a
  provider module.

  Clients may sign in with the provider's ID tokens with
  `id_token_sign_in: true`.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Discovery

  @profile_map [
    id: "sub",
    email: "email",
    email_verified: "email_verified",
    name: "name",
    image: "picture"
  ]

  @impl true
  def config, do: [name: "OAuth", scopes: ["openid", "email", "profile"]]

  @impl true
  def options_schema do
    [
      name: [type: :string, doc: "Generic: the provider's display name."],
      pkce: [type: :boolean, default: true, doc: "Generic: send a PKCE challenge."],
      id_token_sign_in: [
        type: :boolean,
        default: false,
        doc: "Generic: let clients sign in with the provider's ID tokens."
      ],
      profile_map: [
        type: :keyword_list,
        keys:
          Enum.map(@profile_map, fn {key, field} ->
            {key, [type: {:or, [:string, nil]}, default: field]}
          end),
        default: [],
        doc: "Generic: the profile fields holding the user's attributes."
      ]
    ]
  end

  # Discovery from the issuer, unless the endpoints are set by hand.
  @impl true
  def endpoints(options) do
    if is_binary(options[:issuer]) and is_nil(options[:authorize_url]),
      do: [discovery_url: Discovery.url(options[:issuer])],
      else: []
  end

  @impl true
  def map_profile(profile, _tokens, provider) do
    fields = Keyword.merge(@profile_map, provider.options[:profile_map] || [])

    case field(profile, fields[:id]) do
      id when is_binary(id) or is_integer(id) ->
        {:ok,
         %{
           id: to_string(id),
           email: field(profile, fields[:email]),
           email_verified: field(profile, fields[:email_verified]) in [true, "true"],
           name: field(profile, fields[:name]),
           image: field(profile, fields[:image])
         }}

      _missing ->
        {:error, :no_user_id}
    end
  end

  defp field(_profile, nil), do: nil
  defp field(profile, name), do: profile[name]
end
