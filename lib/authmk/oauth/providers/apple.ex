defmodule Authmk.OAuth.Providers.Apple do
  @moduledoc """
  Sign in with Apple (OpenID Connect).

      social_providers: [apple: [client_id: "com.example.web", client_secret: "..."]]

  Create a Services ID at
  <https://developer.apple.com/account/resources/identifiers/list/serviceId>,
  enable Sign in with Apple and add the return URL
  `<base_url>/auth/callback/apple`. `client_id` is the Services ID and
  `client_secret` the JWT you sign with your Sign in with Apple key.

  Apple posts the callback (`response_mode: "form_post"`), and sends the
  user's name only once, on the first sign-in, in a `user` param next to the
  code. Everything else comes from the ID token. Apple has no profile
  pictures. Clients may also sign in with an Apple ID token whose audience is
  `client_id` (or an `audience:`, like the app's bundle id). Native apps
  send Apple the SHA-256 of their nonce, so a token whose nonce is the hash
  of the one sent here passes too.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.{IDToken, Provider}

  @impl true
  def config do
    [
      name: "Apple",
      authorize_url: "https://appleid.apple.com/auth/authorize",
      token_url: "https://appleid.apple.com/auth/token",
      issuer: "https://appleid.apple.com",
      jwks_url: "https://appleid.apple.com/auth/keys",
      scopes: ["email", "name"],
      id_token_sign_in: true,
      id_token_algorithms: ["RS256"],
      id_token_max_age: 3600
    ]
  end

  @impl true
  def verify_id_token(ctx, provider, token, nonce, opts) do
    nonces = if nonce, do: [nonce, :sha256 |> :crypto.hash(nonce) |> Base.encode16(case: :lower)]
    IDToken.verify(ctx, provider, token, nonces, opts)
  end

  # Apple requires form_post when the name or email scope is requested.
  @impl true
  def authorize_params(provider) do
    if provider.options[:response_mode], do: [], else: [response_mode: "form_post"]
  end

  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, claims} <- Provider.default_user_info(tokens, provider, ctx) do
      case name_from_callback(ctx.raw_params["user"]) do
        nil -> {:ok, claims}
        name -> {:ok, Map.put(claims, "name", name)}
      end
    end
  end

  # The `user` param: `{"name": {"firstName": "...", "lastName": "..."}, ...}`.
  # Not signed, so only the name is taken from it.
  defp name_from_callback(user) when is_binary(user) do
    with {:ok, %{"name" => %{} = name}} <- JSON.decode(user),
         full_name when full_name != "" <- full_name(name["firstName"], name["lastName"]) do
      full_name
    else
      _no_name -> nil
    end
  end

  defp name_from_callback(_missing), do: nil

  defp full_name(first, last) do
    [first, last]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.trim()
  end
end
