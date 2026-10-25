defmodule Authmk.OAuth.Providers.Naver do
  @moduledoc """
  Sign in with Naver.

      social_providers: [naver: [client_id: "...", client_secret: "..."]]

  Register an application at <https://developers.naver.com/apps/#/register>
  for Naver Login with the callback URL `<base_url>/auth/callback/naver`.
  Naver doesn't say whether the email is verified, so it never counts as
  verified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Naver",
      authorize_url: "https://nid.naver.com/oauth2.0/authorize",
      token_url: "https://nid.naver.com/oauth2.0/token",
      userinfo_url: "https://openapi.naver.com/v1/nid/me",
      scopes: ["profile", "email"],
      pkce: false
    ]
  end

  # Naver answers errors with HTTP 200 and a result code other than "00".
  @impl true
  def user_info(tokens, provider, ctx) do
    case Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      {:ok, %{"resultcode" => "00", "response" => %{}} = profile} -> {:ok, profile}
      {:ok, _failed} -> {:error, :naver_error}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def map_profile(%{"response" => %{"id" => id} = profile}, _tokens) do
    {:ok,
     %{
       id: to_string(id),
       email: profile["email"],
       email_verified: false,
       name: profile["name"] || profile["nickname"],
       image: profile["profile_image"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_subject}
end
