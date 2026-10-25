defmodule Authmk.OAuth.Providers.Yandex do
  @moduledoc """
  Sign in with Yandex ID.

      social_providers: [yandex: [client_id: "...", client_secret: "..."]]

  Create an app at <https://oauth.yandex.com/client/new> with the redirect
  URI `<base_url>/auth/callback/yandex` and access to the login, email and
  avatar data. Yandex doesn't say whether the email is verified, so it
  counts as unverified.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.HTTP

  @impl true
  def config do
    [
      name: "Yandex",
      authorize_url: "https://oauth.yandex.com/authorize",
      token_url: "https://oauth.yandex.com/token",
      userinfo_url: "https://login.yandex.ru/info?format=json",
      scopes: ["login:info", "login:email", "login:avatar"]
    ]
  end

  # Yandex wants `OAuth <token>`, not `Bearer`.
  @impl true
  def user_info(%{access_token: token}, provider, ctx) when is_binary(token) do
    case HTTP.get(ctx, provider.userinfo_url, [{"authorization", "OAuth " <> token}]) do
      {:ok, 200, %{} = info} -> {:ok, info}
      _failed -> {:error, :no_user_info}
    end
  end

  def user_info(_tokens, _provider, _ctx), do: {:error, :no_access_token}

  @impl true
  def map_profile(%{"id" => id} = info, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: info["default_email"] || List.first(info["emails"] || []),
       email_verified: false,
       name: info["display_name"] || info["real_name"] || info["login"],
       image: avatar(info)
     }}
  end

  def map_profile(_info, _tokens), do: {:error, :no_user_id}

  defp avatar(%{"is_avatar_empty" => false, "default_avatar_id" => id}) when is_binary(id),
    do: "https://avatars.yandex.net/get-yapic/#{id}/islands-200"

  defp avatar(_info), do: nil
end
