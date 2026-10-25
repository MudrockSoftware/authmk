defmodule Authmk.OAuth.Providers.Twitter do
  @moduledoc """
  Sign in with X (Twitter).

      social_providers: [twitter: [client_id: "...", client_secret: "..."]]

  Create a project and app at <https://developer.x.com/en/portal/dashboard>,
  turn on OAuth 2.0 user authentication (type "Web App") with the callback
  URL `<base_url>/auth/callback/twitter`, and allow requesting the user's
  email. The email is X's confirmed email, and counts as verified.

  X shares no email when the app may not request it. The user then gets a
  placeholder address, `<user id>@twitter.placeholder.invalid`, which can't
  receive mail and is never verified, so it can't be used to link accounts.
  """

  use Authmk.OAuth.Provider

  alias Authmk.Email
  alias Authmk.OAuth.Provider

  @confirmed_email_url "https://api.x.com/2/users/me?user.fields=confirmed_email"

  @impl true
  def config do
    [
      name: "Twitter",
      authorize_url: "https://x.com/i/oauth2/authorize",
      token_url: "https://api.x.com/2/oauth2/token",
      userinfo_url: "https://api.x.com/2/users/me?user.fields=profile_image_url",
      scopes: ["users.read", "tweet.read", "offline.access", "users.email"],
      token_auth: :basic
    ]
  end

  # The confirmed email is optional: without it the user gets a placeholder.
  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, %{"data" => user} = profile} <-
           Provider.get_json(ctx, provider.userinfo_url, tokens.access_token) do
      case Provider.get_json(ctx, @confirmed_email_url, tokens.access_token) do
        {:ok, %{"data" => %{"confirmed_email" => email}}} when is_binary(email) ->
          {:ok, %{profile | "data" => Map.put(user, "confirmed_email", email)}}

        _no_email ->
          {:ok, profile}
      end
    end
  end

  @impl true
  def map_profile(%{"data" => %{"id" => id} = user}, _tokens) do
    confirmed_email = user["confirmed_email"]
    email = confirmed_email || user["email"] || placeholder_email(id)

    if Email.valid?(email) do
      {:ok,
       %{
         id: to_string(id),
         email: email,
         email_verified: confirmed_email != nil,
         name: user["name"],
         image: user["profile_image_url"]
       }}
    else
      {:error, :invalid_email}
    end
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  defp placeholder_email(id), do: "#{id}@twitter.placeholder.invalid"
end
