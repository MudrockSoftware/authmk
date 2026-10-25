defmodule Authmk.OAuth.Providers.Discord do
  @moduledoc """
  Sign in with Discord.

      social_providers: [discord: [client_id: "...", client_secret: "..."]]

  Create an application at <https://discord.com/developers/applications> and
  add the redirect `<base_url>/auth/callback/discord` under OAuth2. The email
  comes with Discord's `verified` flag. Users without an avatar get Discord's
  default one.

  Discord asks for consent only once unless `prompt: "consent"` is set (the
  default prompt is `"none"`). To add a bot to a server, request the `bot`
  scope and set `permissions:` (the permission integer).
  """

  use Authmk.OAuth.Provider

  @cdn "https://cdn.discordapp.com"

  @impl true
  def config do
    [
      name: "Discord",
      authorize_url: "https://discord.com/api/oauth2/authorize",
      token_url: "https://discord.com/api/oauth2/token",
      userinfo_url: "https://discord.com/api/users/@me",
      scopes: ["identify", "email"],
      pkce: false
    ]
  end

  @impl true
  def options_schema do
    [
      permissions: [
        type: :non_neg_integer,
        doc: "Discord: bot permissions, sent when the `bot` scope is requested."
      ]
    ]
  end

  @impl true
  def authorize_params(provider) do
    [
      prompt: provider.options[:prompt] || "none",
      permissions: if(bot?(provider), do: provider.options[:permissions])
    ]
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) when is_binary(id) do
    {:ok,
     %{
       id: id,
       email: profile["email"],
       email_verified: profile["verified"] == true,
       name: profile["global_name"] || profile["username"],
       image: avatar_url(profile)
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}

  defp bot?(provider) do
    scopes = if provider.options[:disable_default_scopes], do: [], else: provider.scopes
    "bot" in (scopes ++ provider.options[:scopes])
  end

  defp avatar_url(%{"id" => id, "avatar" => "a_" <> _rest = hash}),
    do: "#{@cdn}/avatars/#{id}/#{hash}.gif"

  defp avatar_url(%{"id" => id, "avatar" => hash}) when is_binary(hash),
    do: "#{@cdn}/avatars/#{id}/#{hash}.png"

  defp avatar_url(profile), do: "#{@cdn}/embed/avatars/#{default_avatar(profile)}.png"

  # Users on the new username system have discriminator "0".
  defp default_avatar(%{"discriminator" => discriminator})
       when is_binary(discriminator) and discriminator != "0",
       do: discriminator |> integer() |> rem(5)

  defp default_avatar(%{"id" => id}), do: id |> integer() |> Bitwise.bsr(22) |> rem(6)

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _not_a_number -> 0
    end
  end
end
