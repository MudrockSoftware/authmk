defmodule Authmk.OAuth.Providers do
  @moduledoc """
  Built-in social providers, and the options every provider takes.

      social_providers: [
        github: [client_id: "...", client_secret: "..."],
        google: [client_id: "...", client_secret: "...", access_type: "offline"],
        acme: [provider: MyApp.Auth.Acme, client_id: "...", client_secret: "..."],
        intranet: [provider: :keycloak, issuer: "https://sso.example.com/realms/staff", ...]
      ]

  `provider:` is your `Authmk.OAuth.Provider` module, or a built-in
  provider's name, to use it under another name (twice, say). `:generic`
  is any OpenID Connect or OAuth 2.0 provider (`Authmk.OAuth.Providers.Generic`).

  ## Options

  #{NimbleOptions.docs(Authmk.OAuth.Providers.Options.schema())}
  """

  alias Authmk.OAuth.{Provider, Providers}
  alias Authmk.OAuth.Providers.Options

  @built_in %{
    apple: Providers.Apple,
    atlassian: Providers.Atlassian,
    auth0: Providers.Auth0,
    cloudflare: Providers.Cloudflare,
    cognito: Providers.Cognito,
    discord: Providers.Discord,
    dropbox: Providers.Dropbox,
    facebook: Providers.Facebook,
    figma: Providers.Figma,
    generic: Providers.Generic,
    github: Providers.GitHub,
    gitlab: Providers.GitLab,
    google: Providers.Google,
    gumroad: Providers.Gumroad,
    hubspot: Providers.HubSpot,
    huggingface: Providers.HuggingFace,
    kakao: Providers.Kakao,
    keycloak: Providers.Keycloak,
    kick: Providers.Kick,
    line: Providers.Line,
    linear: Providers.Linear,
    linkedin: Providers.LinkedIn,
    microsoft: Providers.Microsoft,
    naver: Providers.Naver,
    notion: Providers.Notion,
    okta: Providers.Okta,
    patreon: Providers.Patreon,
    paybin: Providers.Paybin,
    paypal: Providers.PayPal,
    polar: Providers.Polar,
    railway: Providers.Railway,
    reddit: Providers.Reddit,
    roblox: Providers.Roblox,
    salesforce: Providers.Salesforce,
    slack: Providers.Slack,
    spotify: Providers.Spotify,
    tiktok: Providers.TikTok,
    twitch: Providers.Twitch,
    twitter: Providers.Twitter,
    vercel: Providers.Vercel,
    vk: Providers.VK,
    wechat: Providers.WeChat,
    yandex: Providers.Yandex,
    zoom: Providers.Zoom
  }

  @doc "Built-in provider modules by name."
  @spec built_in() :: %{atom() => module()}
  def built_in, do: @built_in

  @doc "Builds the configured providers. Raises on unknown providers or invalid options."
  @spec build(keyword()) :: %{atom() => Provider.t()}
  def build(social_providers) do
    Map.new(social_providers, fn {id, options} ->
      module = module(id, options[:provider])
      Code.ensure_loaded!(module)
      schema = Keyword.merge(Options.schema().schema, module.options_schema())
      {id, Provider.new(id, module, NimbleOptions.validate!(options, schema))}
    end)
  end

  defp module(id, nil), do: Map.get(@built_in, id) || raise(ArgumentError, unknown(id))
  defp module(_id, name) when is_map_key(@built_in, name), do: Map.fetch!(@built_in, name)
  defp module(_id, module), do: module

  defp unknown(id) do
    "unknown social provider #{inspect(id)}. Built in: #{inspect(Map.keys(@built_in))}. " <>
      "For others, pass `provider: YourModule` (see Authmk.OAuth.Provider)"
  end
end
