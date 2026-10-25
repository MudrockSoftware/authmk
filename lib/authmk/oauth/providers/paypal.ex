defmodule Authmk.OAuth.Providers.PayPal do
  @moduledoc """
  Sign in with PayPal (Log in with PayPal).

      social_providers: [paypal: [client_id: "...", client_secret: "..."]]

  Create an app at <https://developer.paypal.com/dashboard/applications>,
  enable "Log in with PayPal" with the return URL
  `<base_url>/auth/callback/paypal`, and pick the user information to share
  (include the email) there: PayPal takes no scopes in the request. The
  client secret is required.

  The endpoints are PayPal's sandbox; set `environment: :live` for live.

  When PayPal returns an ID token, its subject must match the profile's, or
  sign-in fails.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider
  alias Authmk.URL

  @impl true
  def config do
    [
      name: "PayPal",
      scopes: [],
      token_auth: :basic
    ]
  end

  @impl true
  def options_schema do
    [
      client_secret: [type: :string, required: true],
      environment: [
        type: {:in, [:sandbox, :live]},
        default: :sandbox,
        doc: "PayPal: `:sandbox` or `:live`."
      ]
    ]
  end

  @impl true
  def endpoints(options) do
    {web, api} =
      if options[:environment] == :live,
        do: {"https://www.paypal.com", "https://api-m.paypal.com"},
        else: {"https://www.sandbox.paypal.com", "https://api-m.sandbox.paypal.com"}

    [
      authorize_url: web <> "/signin/authorize",
      token_url: api <> "/v1/oauth2/token",
      userinfo_url: api <> "/v1/identity/oauth2/userinfo"
    ]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    url = URL.append_query(provider.userinfo_url, schema: "paypalv1.1")

    with {:ok, profile} <- Provider.get_json(ctx, url, tokens.access_token),
         :ok <- same_subject(profile, tokens.id_token) do
      {:ok, profile}
    end
  end

  # The account id is PayPal's `user_id`, which existing accounts are keyed by.
  @impl true
  def map_profile(%{"user_id" => user_id} = profile, _tokens) when is_binary(user_id) do
    {:ok,
     %{
       id: user_id,
       email: profile["email"],
       email_verified: profile["email_verified"] == true,
       name: profile["name"],
       image: profile["picture"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_subject}

  # OpenID Connect ties the profile to the ID token by its subject.
  defp same_subject(_profile, nil), do: :ok

  defp same_subject(profile, id_token) do
    subject = id_token_subject(id_token)

    if is_binary(subject) and subject == (profile["sub"] || profile["user_id"]),
      do: :ok,
      else: {:error, :subject_mismatch}
  end

  # Unverified: the ID token came straight from PayPal's token endpoint over TLS.
  defp id_token_subject(token) do
    %JOSE.JWT{fields: claims} = JOSE.JWT.peek_payload(token)
    claims["sub"]
  rescue
    _malformed -> nil
  end
end
