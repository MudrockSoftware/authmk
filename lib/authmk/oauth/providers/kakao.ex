defmodule Authmk.OAuth.Providers.Kakao do
  @moduledoc """
  Sign in with Kakao.

      social_providers: [kakao: [client_id: "...", client_secret: "..."]]

  Create an app at <https://developers.kakao.com/console/app>, enable Kakao
  Login with the redirect URI `<base_url>/auth/callback/kakao`, and use its
  REST API key as the client id. The client secret is optional (Kakao Login
  security settings). The email counts as verified only when Kakao says it is
  both valid and verified.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Kakao",
      authorize_url: "https://kauth.kakao.com/oauth/authorize",
      token_url: "https://kauth.kakao.com/oauth/token",
      userinfo_url: "https://kapi.kakao.com/v2/user/me",
      scopes: ["account_email", "profile_image", "profile_nickname"],
      pkce: false
    ]
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) do
    account = profile["kakao_account"] || %{}
    kakao_profile = account["profile"] || %{}

    {:ok,
     %{
       id: to_string(id),
       email: account["email"],
       email_verified: account["is_email_valid"] == true and account["is_email_verified"] == true,
       name: kakao_profile["nickname"] || account["name"],
       image: kakao_profile["profile_image_url"] || kakao_profile["thumbnail_image_url"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_subject}
end
