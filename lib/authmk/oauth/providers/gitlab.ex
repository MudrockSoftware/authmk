defmodule Authmk.OAuth.Providers.GitLab do
  @moduledoc """
  Sign in with GitLab.

      social_providers: [gitlab: [client_id: "...", client_secret: "..."]]

  Create an application at <https://gitlab.com/-/user_settings/applications>
  with the `read_user` scope and the redirect URI
  `<base_url>/auth/callback/gitlab`. The email counts as verified only when
  GitLab says so. Blocked or locked GitLab users can't sign in.

  For a self-managed GitLab, set `instance_url: "https://gitlab.example.com"`.
  """

  use Authmk.OAuth.Provider

  @impl true
  def config do
    [
      name: "GitLab",
      scopes: ["read_user"]
    ]
  end

  @impl true
  def options_schema do
    [
      instance_url: [
        type: :string,
        default: "https://gitlab.com",
        doc: "GitLab: a self-managed instance's URL."
      ]
    ]
  end

  @impl true
  def endpoints(options) do
    base = String.trim_trailing(options[:instance_url] || "https://gitlab.com", "/")

    [
      authorize_url: base <> "/oauth/authorize",
      token_url: base <> "/oauth/token",
      userinfo_url: base <> "/api/v4/user"
    ]
  end

  @impl true
  def map_profile(%{"id" => id} = profile, _tokens) when is_integer(id) or is_binary(id) do
    if profile["state"] == "active" and profile["locked"] != true do
      {:ok,
       %{
         id: to_string(id),
         email: profile["email"],
         email_verified: profile["email_verified"] == true,
         name: profile["name"] || profile["username"],
         image: profile["avatar_url"]
       }}
    else
      {:error, :user_not_active}
    end
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
