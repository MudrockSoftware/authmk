defmodule Authmk.Plugins.SSO.Management do
  @moduledoc false
  # Registering and managing providers. A provider of one's own needs only a
  # session; one for an organization needs the app's `can_manage`.

  alias Authmk.{Context, Error}
  alias Authmk.Plugins.SSO.{Config, Domains, Providers}

  def register(%Context{params: params} = ctx) do
    with :ok <- allowed(ctx, :register, params.organization_id),
         {:ok, provider} <- Providers.register(ctx, params) do
      {:ok, Providers.to_public(provider), ctx}
    end
  end

  def list(%Context{params: params} = ctx) do
    with :ok <- allowed(ctx, :read, params.organization_id) do
      {:ok, ctx |> Providers.list(params.organization_id) |> Enum.map(&Providers.to_public/1),
       ctx}
    end
  end

  def delete(%Context{params: params} = ctx) do
    with {:ok, provider} <- managed(ctx, params.provider_id, :delete),
         :ok <- Providers.delete(ctx, provider.provider_id) do
      {:ok, %{success: true}, ctx}
    end
  end

  def request_domain_verification(%Context{params: params} = ctx) do
    with {:ok, provider} <- managed(ctx, params.provider_id, :register),
         :ok <- has_domain(provider),
         {:ok, challenge} <- Domains.request(ctx, provider) do
      {:ok, challenge, ctx}
    end
  end

  def verify_domain(%Context{params: params} = ctx) do
    with {:ok, provider} <- managed(ctx, params.provider_id, :register),
         :ok <- has_domain(provider),
         :ok <- Domains.verify(ctx, provider) do
      {:ok, %{domain_verified: true}, ctx}
    end
  end

  # Database providers the user may manage; config ones are managed in config.
  defp managed(%Context{user: user} = ctx, provider_id, action) do
    case Providers.find(ctx, provider_id) do
      %{record: nil} -> {:error, not_found()}
      nil -> {:error, not_found()}
      %{organization_id: nil, user_id: owner} = provider when owner == user.id -> {:ok, provider}
      %{organization_id: nil} -> {:error, not_found()}
      provider -> with :ok <- allowed(ctx, action, provider.organization_id), do: {:ok, provider}
    end
  end

  defp allowed(_ctx, _action, nil), do: :ok

  defp allowed(ctx, action, organization_id) do
    case Config.opts(ctx)[:can_manage] do
      nil ->
        {:error, Error.new(:forbidden)}

      can? ->
        if can?.(action, organization_id, ctx) == true,
          do: :ok,
          else: {:error, Error.new(:forbidden)}
    end
  end

  defp has_domain(%{domain: domain}) when is_binary(domain), do: :ok

  defp has_domain(_provider),
    do: {:error, Error.custom(:invalid_sso_provider, 400, "The provider has no domain")}

  defp not_found, do: Error.custom(:sso_provider_not_found, 404, "No such provider")
end
