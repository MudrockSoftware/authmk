defmodule Authmk.OAuth.Providers.Reddit do
  @moduledoc """
  Sign in with Reddit.

      social_providers: [reddit: [client_id: "...", client_secret: "...", duration: "permanent"]]

  Create a "web app" at <https://www.reddit.com/prefs/apps> with the redirect
  URI `<base_url>/auth/callback/reddit`. Set `duration: "permanent"` to get
  a refresh token.

  Reddit shares no email. Each user gets a stable placeholder,
  `<reddit id>@reddit.placeholder.invalid` (`.invalid` is a reserved domain
  that never receives mail), which never counts as verified.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Reddit",
      authorize_url: "https://www.reddit.com/api/v1/authorize",
      token_url: "https://www.reddit.com/api/v1/access_token",
      userinfo_url: "https://oauth.reddit.com/api/v1/me",
      scopes: ["identity"],
      pkce: false,
      token_auth: :basic
    ]
  end

  @impl true
  def options_schema do
    [
      duration: [
        type: {:in, ["temporary", "permanent"]},
        doc: ~s(Reddit: "permanent" for a refresh token.)
      ]
    ]
  end

  @impl true
  def authorize_params(provider), do: [duration: provider.options[:duration]]

  @impl true
  def map_profile(profile, _tokens) do
    with {:ok, email} <- placeholder_email(profile["id"]) do
      {:ok,
       %{
         id: profile["id"],
         email: email,
         email_verified: false,
         name: profile["name"],
         image: icon(profile["icon_img"])
       }}
    end
  end

  defp placeholder_email(id) when is_binary(id) do
    if id =~ ~r/\A[\w-]+\z/,
      do: {:ok, id <> "@reddit.placeholder.invalid"},
      else: {:error, :invalid_subject}
  end

  defp placeholder_email(_id), do: {:error, :no_subject}

  # Reddit adds sizing and signature params to the icon URL.
  defp icon(url) when is_binary(url), do: url |> String.split("?") |> hd()
  defp icon(_none), do: nil
end
