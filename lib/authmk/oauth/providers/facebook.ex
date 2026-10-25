defmodule Authmk.OAuth.Providers.Facebook do
  @moduledoc """
  Sign in with Facebook.

      social_providers: [facebook: [client_id: "...", client_secret: "..."]]

  Create an app at <https://developers.facebook.com/apps> with Facebook
  Login, and add `<base_url>/auth/callback/facebook` as a valid OAuth
  redirect URI. The client secret is required.

  Facebook access tokens work for any app at the Graph API, so before
  trusting a profile, authmk asks Facebook (`/debug_token`) whether the
  token was issued to this app, and for which user. The email counts as
  verified only when the Graph profile says so.

  Clients may also sign in with a Limited Login ID token (iOS), and an ID
  token from the code exchange (with the `openid` scope) is used instead of
  the Graph API. ID tokens carry no verified flag, so their email counts as
  unverified.

  Options:

    * `fields:` - more Graph profile fields to fetch, on top of `id`,
      `name`, `email` and `picture`
    * `config_id:` - the Facebook Login for Business configuration to use
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.{HTTP, Provider}
  alias Authmk.URL

  @graph "https://graph.facebook.com"
  @default_fields ["id", "name", "email", "picture"]

  @impl true
  def config do
    [
      name: "Facebook",
      authorize_url: "https://www.facebook.com/v24.0/dialog/oauth",
      token_url: @graph <> "/v24.0/oauth/access_token",
      userinfo_url: @graph <> "/me",
      issuer: "https://www.facebook.com",
      jwks_url: "https://limited.facebook.com/.well-known/oauth/openid/jwks/",
      scopes: ["email", "public_profile"],
      pkce: false,
      id_token_sign_in: true
    ]
  end

  @impl true
  def options_schema do
    [
      client_secret: [type: :string, required: true],
      fields: [
        type: {:list, :string},
        default: [],
        doc: "Facebook: more Graph profile fields to fetch."
      ],
      config_id: [type: :string, doc: "Facebook: the Login for Business configuration."]
    ]
  end

  @impl true
  def authorize_params(provider), do: [config_id: provider.options[:config_id]]

  # An ID token's claims, verified against Facebook's keys, or the Graph profile.
  @impl true
  def user_info(%{claims: %{} = claims}, _provider, _ctx), do: {:ok, claims}
  def user_info(tokens, provider, ctx), do: graph_profile(tokens, provider, ctx)

  @impl true
  def map_profile(%{"sub" => sub} = claims, _tokens) when is_binary(sub) do
    {:ok,
     %{
       id: sub,
       email: claims["email"],
       email_verified: false,
       name: claims["name"],
       image: claims["picture"]
     }}
  end

  def map_profile(%{"id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["name"],
       image: get_in(profile, ["picture", "data", "url"])
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  # The profile must belong to the user the token was issued for.
  defp graph_profile(%{access_token: token}, provider, ctx) when is_binary(token) do
    url = URL.append_query(provider.userinfo_url, fields: fields(provider))

    with {:ok, user_id} <- token_user(ctx, provider, token),
         {:ok, %{"id" => ^user_id} = profile} <- Provider.get_json(ctx, url, token) do
      {:ok, profile}
    else
      {:ok, _other_user} -> {:error, :token_user_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp graph_profile(_tokens, _provider, _ctx), do: {:error, :no_access_token}

  # The user id of a valid token issued to this app.
  defp token_user(ctx, provider, token) do
    url =
      URL.append_query(@graph <> "/debug_token",
        input_token: token,
        access_token: provider.client_id <> "|" <> provider.client_secret
      )

    case HTTP.get(ctx, url) do
      {:ok, 200, %{"data" => %{"is_valid" => true, "app_id" => app_id, "user_id" => user_id}}}
      when app_id == provider.client_id and is_binary(user_id) ->
        {:ok, user_id}

      _invalid ->
        {:error, :invalid_access_token}
    end
  end

  defp fields(provider),
    do: Enum.join(Enum.uniq(@default_fields ++ provider.options[:fields]), ",")
end
