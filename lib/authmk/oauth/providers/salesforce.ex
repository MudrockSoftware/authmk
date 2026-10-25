defmodule Authmk.OAuth.Providers.Salesforce do
  @moduledoc """
  Sign in with Salesforce.

      social_providers: [salesforce: [client_id: "...", client_secret: "..."]]

  Create a connected app (or external client app) in Salesforce Setup with
  the callback URL `<base_url>/auth/callback/salesforce`, the `openid`,
  `email` and `profile` scopes, and PKCE enabled.

  The endpoints default to production (`login.salesforce.com`). Set
  `environment: :sandbox` for `test.salesforce.com`, or `login_url:` for a
  My Domain login, like `"https://example.my.salesforce.com"`.

  Accounts are keyed by the Salesforce `user_id`. The email counts as
  verified only when Salesforce says so.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider

  @impl true
  def config, do: [name: "Salesforce", scopes: ["openid", "email", "profile"]]

  @impl true
  def options_schema do
    [
      environment: [
        type: {:in, [:production, :sandbox]},
        default: :production,
        doc: "Salesforce: `:production` or `:sandbox`."
      ],
      login_url: [type: :string, doc: "Salesforce: a My Domain login URL."]
    ]
  end

  @impl true
  def endpoints(options) do
    base = String.trim_trailing(login_url(options), "/") <> "/services/oauth2"

    [
      authorize_url: base <> "/authorize",
      token_url: base <> "/token",
      userinfo_url: base <> "/userinfo"
    ]
  end

  defp login_url(options) do
    cond do
      options[:login_url] -> options[:login_url]
      options[:environment] == :sandbox -> "https://test.salesforce.com"
      true -> "https://login.salesforce.com"
    end
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    Provider.get_json(ctx, provider.userinfo_url, tokens.access_token)
  end

  @impl true
  def map_profile(%{"user_id" => user_id} = profile, _tokens) when is_binary(user_id) do
    photos = profile["photos"] || %{}

    {:ok,
     %{
       id: user_id,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["name"],
       image: photos["picture"] || photos["thumbnail"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_user_id}
end
