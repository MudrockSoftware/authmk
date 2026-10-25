defmodule Authmk.OAuth.Discovery do
  @moduledoc """
  OpenID Connect discovery: reads a provider's
  `/.well-known/openid-configuration` and fills in the endpoints its config
  leaves out. Endpoints set explicitly always win.

  The document's `issuer` must be the discovery URL without the
  `/.well-known/openid-configuration` suffix, and the provider's `issuer`
  when one is set, so a document can't point ID token checks at another
  issuer. Documents are cached for an hour.
  """

  alias Authmk.Context
  alias Authmk.OAuth.HTTP
  alias Authmk.Storage.ETS

  @cache_ttl 3600
  @suffix "/.well-known/openid-configuration"

  @doc "The provider with discovered endpoints filled in, or an error when discovery fails."
  @spec resolve(Context.t(), Authmk.OAuth.Provider.t()) ::
          {:ok, Authmk.OAuth.Provider.t()} | {:error, :discovery_failed}
  def resolve(_ctx, %{discovery_url: nil} = provider), do: {:ok, provider}

  def resolve(ctx, provider) do
    with {:ok, document} <- document(ctx, provider.discovery_url),
         :ok <- check_issuer(provider, document["issuer"]) do
      {:ok, fill(provider, document)}
    end
  end

  @doc "The discovery URL for an issuer."
  @spec url(String.t()) :: String.t()
  def url(issuer), do: String.trim_trailing(issuer, "/") <> @suffix

  defp check_issuer(provider, issuer) when is_binary(issuer) do
    expected = String.replace_suffix(provider.discovery_url, @suffix, "")
    configured = List.wrap(provider.issuer)

    if same_url?(issuer, expected) and
         (configured == [] or Enum.any?(configured, &same_url?(&1, issuer))),
       do: :ok,
       else: {:error, :discovery_failed}
  end

  defp check_issuer(_provider, _missing), do: {:error, :discovery_failed}

  # Issuers differ in trailing slashes only (`https://tenant.auth0.com/`).
  defp same_url?(a, b), do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  defp fill(provider, document) do
    %{
      provider
      | authorize_url: provider.authorize_url || document["authorization_endpoint"],
        token_url: provider.token_url || document["token_endpoint"],
        userinfo_url: provider.userinfo_url || document["userinfo_endpoint"],
        jwks_url: provider.jwks_url || document["jwks_uri"],
        # The document's spelling: ID tokens carry exactly that.
        issuer: document["issuer"],
        end_session_url: provider.end_session_url || document["end_session_endpoint"],
        token_auth: token_auth(provider, document["token_endpoint_auth_methods_supported"])
    }
  end

  # Unless the app chose, HTTP Basic when the provider takes only that.
  defp token_auth(%{options: options} = provider, methods) when is_list(methods) do
    if is_nil(options[:token_auth]) and "client_secret_basic" in methods and
         "client_secret_post" not in methods,
       do: :basic,
       else: provider.token_auth
  end

  defp token_auth(provider, _methods), do: provider.token_auth

  defp document(%Context{config: config} = ctx, url) do
    table = [table: ETS.table(config.auth)]
    key = "discovery:" <> url

    case ETS.get(table, key) do
      nil -> fetch(ctx, table, key, url)
      json -> {:ok, JSON.decode!(json)}
    end
  end

  defp fetch(ctx, table, key, url) do
    case HTTP.get(ctx, url) do
      {:ok, 200, %{"authorization_endpoint" => _, "token_endpoint" => _} = document} ->
        :ok = ETS.put(table, key, JSON.encode!(document), @cache_ttl)
        {:ok, document}

      _failed ->
        {:error, :discovery_failed}
    end
  end
end
