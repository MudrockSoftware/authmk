defmodule Authmk.Plugins.SSO.Providers do
  @moduledoc false
  # Identity providers: from config (`default_providers`) or registered at
  # runtime, usually one per organization. Client secrets are stored
  # encrypted.

  import Ecto.Query

  alias Authmk.{Context, Crypto, Error, Store, URL}
  alias Authmk.OAuth.{Discovery, Provider, PublicHost}
  alias Authmk.OAuth.Providers.Generic
  alias Authmk.Plugins.SSO.Config

  @secret_purpose "sso-client-secret"
  @id_format ~r/\A[a-z0-9][a-z0-9-]{1,62}\z/
  @domain_format ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  @doc "A provider by id: config first, then the database. `nil` when unknown."
  def find(ctx, provider_id) when is_binary(provider_id) do
    configured(ctx, provider_id) ||
      ctx |> Store.get_by(:sso_provider, provider_id: provider_id) |> from_record(ctx)
  end

  def find(_ctx, _provider_id), do: nil

  @doc "The provider for an email domain. With `domain_verification`, verified ones only."
  def for_domain(ctx, domain) when is_binary(domain) do
    domain = String.downcase(domain)
    verified_only = Config.opts(ctx)[:domain_verification]

    Enum.find(defaults(ctx), &(&1.domain == domain)) ||
      ctx
      |> Store.list(
        :sso_provider,
        from(p in Store.module(ctx, :sso_provider), where: p.domain == ^domain)
      )
      |> Enum.find(&(&1.domain_verified or not verified_only))
      |> from_record(ctx)
  end

  def for_domain(_ctx, _domain), do: nil

  @doc "An organization's provider."
  def for_organization(ctx, organization_id) when is_binary(organization_id) do
    Enum.find(defaults(ctx), &(&1.organization_id == organization_id)) ||
      ctx |> Store.get_by(:sso_provider, organization_id: organization_id) |> from_record(ctx)
  end

  def for_organization(_ctx, _organization_id), do: nil

  @doc "Providers the user registered, or their organizations' (with `can_manage`)."
  def list(%Context{user: user} = ctx, organization_id) do
    module = Store.module(ctx, :sso_provider)

    query =
      if organization_id,
        do: from(p in module, where: p.organization_id == ^organization_id),
        else: from(p in module, where: p.user_id == ^user.id and is_nil(p.organization_id))

    ctx |> Store.list(:sso_provider, query) |> Enum.map(&from_record(&1, ctx))
  end

  @doc "Registers an OpenID Connect provider. Its issuer must answer discovery."
  def register(%Context{user: user} = ctx, params) do
    oidc = params.oidc_config

    with :ok <-
           check(
             Regex.match?(@id_format, params.provider_id),
             "provider_id must be lowercase letters, digits and dashes"
           ),
         :ok <- check(is_nil(find(ctx, params.provider_id)), "provider_id is taken"),
         :ok <-
           check(
             is_nil(params.domain) or Regex.match?(@domain_format, String.downcase(params.domain)),
             "Not a domain name"
           ),
         :ok <-
           check(
             is_binary(oidc["client_id"]) and is_binary(oidc["client_secret"]),
             "oidc_config needs client_id and client_secret"
           ),
         {:ok, provider} <- discover(ctx, params, oidc) do
      attrs = %{
        provider_id: params.provider_id,
        type: "oidc",
        issuer: provider.issuer,
        domain: params.domain && String.downcase(params.domain),
        organization_id: params.organization_id,
        user_id: user.id,
        oidc_config:
          JSON.encode!(%{
            "client_id" => oidc["client_id"],
            "client_secret" => Crypto.encrypt(ctx.config, @secret_purpose, oidc["client_secret"]),
            "discovery_url" => provider.discovery_url,
            "scopes" => oidc["scopes"] || ["openid", "email", "profile"]
          })
      }

      with {:ok, record} <- Store.insert(ctx, :sso_provider, attrs),
           do: {:ok, from_record(record, ctx)}
    end
  end

  # The issuer is fetched from this server: only public hosts, over HTTPS.
  defp discover(ctx, params, oidc) do
    uri = URI.parse(params.issuer || "")

    with :ok <-
           check(
             uri.scheme == "https" and uri.host not in [nil, ""],
             "issuer must be an HTTPS URL"
           ),
         :ok <-
           check(
             PublicHost.check(uri.host, Config.opts(ctx)[:resolve_host]) == :ok,
             "The issuer's host isn't public"
           ) do
      provider =
        oauth_provider(ctx, %{provider_id: params.provider_id, issuer: params.issuer, oidc: oidc})

      case Discovery.resolve(ctx, provider) do
        {:ok, provider} -> {:ok, provider}
        _failed -> check(false, "The issuer's discovery document couldn't be read")
      end
    end
  end

  @doc "Deletes a provider registered in the database."
  def delete(ctx, provider_id) do
    case Store.get_by(ctx, :sso_provider, provider_id: provider_id) do
      nil -> {:error, not_found()}
      record -> with {:ok, _record} <- Store.delete(ctx, :sso_provider, record), do: :ok
    end
  end

  @doc "Marks a provider's domain verified."
  def mark_verified(ctx, provider) do
    with {:ok, _record} <-
           Store.update(ctx, :sso_provider, provider.record, %{domain_verified: true}),
         do: :ok
  end

  @doc "The OAuth client side of a provider, for the authorization code flow."
  def oauth_provider(ctx, provider) do
    oidc = provider.oidc

    path =
      if Config.opts(ctx)[:shared_redirect_uri],
        do: "/sso/callback",
        else: "/sso/callback/" <> provider.provider_id

    Provider.new(provider.provider_id, Generic,
      client_id: oidc["client_id"],
      client_secret: oidc["client_secret"],
      issuer: provider.issuer,
      discovery_url: oidc["discovery_url"] || Discovery.url(provider.issuer),
      scopes: oidc["scopes"] || ["openid", "email", "profile"],
      redirect_uri: URL.endpoint(ctx, path)
    )
  end

  @doc "What the management endpoints show. Never the secret."
  def to_public(provider) do
    %{
      provider_id: provider.provider_id,
      type: provider.type,
      issuer: provider.issuer,
      domain: provider.domain,
      domain_verified: provider.domain_verified,
      organization_id: provider.organization_id,
      client_id: provider.oidc["client_id"]
    }
  end

  defp configured(ctx, provider_id),
    do: Enum.find(defaults(ctx), &(&1.provider_id == provider_id))

  defp defaults(ctx) do
    for entry <- Config.opts(ctx)[:default_providers] do
      %{
        provider_id: entry[:provider_id],
        type: "oidc",
        issuer: entry[:issuer],
        domain: entry[:domain] && String.downcase(entry[:domain]),
        domain_verified: true,
        organization_id: entry[:organization_id],
        user_id: nil,
        record: nil,
        oidc: %{
          "client_id" => entry[:client_id],
          "client_secret" => entry[:client_secret],
          "discovery_url" => entry[:discovery_url],
          "scopes" => entry[:scopes]
        }
      }
    end
  end

  defp from_record(nil, _ctx), do: nil

  defp from_record(record, %Context{config: config}) do
    oidc = JSON.decode!(record.oidc_config || "{}")

    secret =
      case Crypto.decrypt(config, @secret_purpose, oidc["client_secret"] || "") do
        {:ok, secret} -> secret
        :error -> nil
      end

    %{
      provider_id: record.provider_id,
      type: record.type,
      issuer: record.issuer,
      domain: record.domain,
      domain_verified: record.domain_verified,
      organization_id: record.organization_id,
      user_id: record.user_id,
      record: record,
      oidc: Map.put(oidc, "client_secret", secret)
    }
  end

  defp check(true, _description), do: :ok

  defp check(_false, description),
    do: {:error, Error.custom(:invalid_sso_provider, 400, description)}

  defp not_found, do: Error.custom(:sso_provider_not_found, 404, "No such provider")
end
