defmodule Authmk.OAuth.Providers.VK do
  @moduledoc """
  Sign in with VK ID.

      social_providers: [vk: [client_id: "...", client_secret: "..."]]

  Create an app at <https://id.vk.com/about/business/go> with the redirect
  URL `<base_url>/auth/callback/vk`. The profile comes from VK ID's
  `user_info` endpoint. VK doesn't say whether it verified the email, so it
  counts as unverified. Users who don't share an email can't sign in.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.HTTP

  @impl true
  def config do
    [
      name: "VK",
      authorize_url: "https://id.vk.com/authorize",
      token_url: "https://id.vk.com/oauth2/auth",
      userinfo_url: "https://id.vk.com/oauth2/user_info",
      scopes: ["email", "phone"]
    ]
  end

  # VK takes the access token in a form, not in a bearer header.
  @impl true
  def user_info(tokens, provider, ctx) do
    form = [access_token: tokens.access_token, client_id: provider.client_id]

    case HTTP.post_form(ctx, provider.userinfo_url, form) do
      {:ok, 200, %{"user" => %{}} = profile} -> {:ok, profile}
      {:ok, status, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def map_profile(%{"user" => %{"user_id" => id} = user}, _tokens) do
    {:ok,
     %{
       id: to_string(id),
       email: user["email"],
       email_verified: false,
       name: full_name(user),
       image: user["avatar"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  defp full_name(user) do
    case [user["first_name"], user["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ") do
      "" -> nil
      name -> name
    end
  end
end
