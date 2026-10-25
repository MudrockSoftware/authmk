defmodule Authmk.OAuth.Providers.HuggingFace do
  @moduledoc """
  Sign in with Hugging Face.

      social_providers: [huggingface: [client_id: "...", client_secret: "..."]]

  Create an OAuth app at <https://huggingface.co/settings/connected-applications>
  with the redirect URL `<base_url>/auth/callback/huggingface` and the
  `openid`, `profile` and `email` scopes. The profile comes from the userinfo
  endpoint, with Hugging Face's `email_verified` flag.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "Hugging Face",
      authorize_url: "https://huggingface.co/oauth/authorize",
      token_url: "https://huggingface.co/oauth/token",
      userinfo_url: "https://huggingface.co/oauth/userinfo",
      scopes: ["openid", "profile", "email"]
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)
  end

  @impl true
  def map_profile(%{"sub" => sub} = profile, _tokens) when is_binary(sub) do
    {:ok,
     %{
       id: sub,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["name"] || profile["preferred_username"],
       image: profile["picture"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_subject}
end
