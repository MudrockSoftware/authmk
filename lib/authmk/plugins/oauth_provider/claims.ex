defmodule Authmk.Plugins.OAuthProvider.Claims do
  @moduledoc false
  # What scopes reveal about a user, for ID tokens and the user info
  # endpoint.

  # Claims the protocol sets; the app's `claims` function can't replace them.
  @protected ~w(iss sub aud exp iat nbf auth_time nonce acr amr azp at_hash c_hash sid jti scope client_id cnf)

  @doc "The subject identifier for `user`: the same for every client."
  def subject(user), do: to_string(user.id)

  @doc """
  The subject identifier `client` sees: pairwise ones differ per site (the
  redirect URIs' host), so sites can't link their users.
  """
  def subject(user, %{subject_type: "pairwise"} = client, opts) do
    data = sector(client) <> ":" <> to_string(user.id)
    :crypto.mac(:hmac, :sha256, opts[:pairwise_secret], data) |> Base.url_encode64(padding: false)
  end

  def subject(user, _client, _opts), do: subject(user)

  defp sector(client),
    do:
      client.redirect_uris
      |> String.split(" ", trim: true)
      |> hd()
      |> URI.parse()
      |> Map.fetch!(:host)

  @doc "The user's claims for `scopes`, plus the app's own."
  def user_claims(user, client, scopes, opts) do
    standard =
      %{"sub" => subject(user, client, opts)}
      |> merge_if("profile" in scopes, %{
        "name" => user.name,
        "picture" => Map.get(user, :image),
        "updated_at" => DateTime.to_unix(user.updated_at)
      })
      |> merge_if("email" in scopes, %{
        "email" => user.email,
        "email_verified" => user.email_verified
      })

    Map.merge(custom(user, client, scopes, opts), standard)
  end

  @doc "Drops protocol claims from claims an app supplies."
  def without_protected(claims),
    do: claims |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.drop(@protected)

  defp custom(user, client, scopes, opts) do
    case opts[:claims] do
      nil -> %{}
      claims -> without_protected(claims.(%{user: user, client: client, scopes: scopes}))
    end
  end

  defp merge_if(claims, true, more), do: Map.merge(claims, more)
  defp merge_if(claims, false, _more), do: claims
end
