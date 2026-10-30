defmodule Authmk.Dashboard.Data do
  @moduledoc false
  # The dashboard's reads, as JSON-ready maps, through authmk's store: the
  # SSO, service accounts and the audit log here, and helpers the
  # other readers (Data.Users, Data.Organizations, Data.Analytics...) share.
  # Every query is bounded, and works on SQLite, PostgreSQL, MySQL and
  # MariaDB.

  import Ecto.Query

  alias Authmk.{Context, Store}
  alias Authmk.Plugins.AuditLog

  @page 50

  def page_size, do: @page

  def enabled?(%Context{config: config}, plugin),
    do: plugin in Enum.map(config.plugins, &elem(&1, 0))

  def model?(%Context{config: config}, model), do: Map.has_key?(config.schema.models, model)

  def field?(%Context{config: config} = ctx, model, field),
    do: model?(ctx, model) and Enum.any?(config.schema.models[model].fields, &(&1.name == field))

  @doc "A record by id, or `nil` (also for ids that aren't valid ids)."
  def safe_get(ctx, model, id) do
    if model?(ctx, model), do: Store.get_by(ctx, model, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Limits a query on users to the members of an organization."
  def in_organization(query, _ctx, nil), do: query

  def in_organization(query, ctx, organization_id) do
    case safe_get(ctx, :organization, organization_id) do
      nil ->
        where(query, false)

      organization ->
        members =
          from(m in Store.module(ctx, :member),
            where: m.organization_id == ^organization.id,
            select: m.user_id
          )

        where(query, [u], u.id in subquery(members))
    end
  end

  def escape_like(term),
    do:
      term |> String.replace("!", "!!") |> String.replace("%", "!%") |> String.replace("_", "!_")

  ## Users and subscriptions, as the dashboard shows them

  def user(user) do
    %{
      id: to_string(user.id),
      email: user.email,
      name: user.name,
      image: Map.get(user, :image),
      email_verified: user.email_verified,
      role: Map.get(user, :role),
      banned: Map.get(user, :banned),
      ban_reason: Map.get(user, :ban_reason),
      ban_expires: Map.get(user, :ban_expires),
      two_factor_enabled: Map.get(user, :two_factor_enabled),
      last_sign_in_at: Map.get(user, :last_sign_in_at),
      created_at: user.inserted_at
    }
  end

  def subscription(subscription) do
    %{
      id: to_string(subscription.id),
      provider: subscription.provider,
      reference_type: subscription.reference_type,
      reference_id: subscription.reference_id,
      plan: subscription.plan,
      price_id: subscription.price_id,
      status: subscription.status,
      seats: subscription.seats,
      period_start: subscription.period_start,
      period_end: subscription.period_end,
      cancel_at_period_end: subscription.cancel_at_period_end,
      canceled_at: subscription.canceled_at,
      trial_end: subscription.trial_end,
      created_at: subscription.inserted_at
    }
  end

  ## SSO and SCIM

  def sso(ctx) do
    %{
      providers: Enum.map(all(ctx, :sso_provider), &sso_provider/1),
      connections: Enum.map(all(ctx, :scim_connection), &scim_connection/1)
    }
  end

  def all(ctx, model, limit \\ 200) do
    if model?(ctx, model),
      do:
        Store.list(
          ctx,
          model,
          from(r in Store.module(ctx, model), order_by: [desc: r.inserted_at], limit: ^limit)
        ),
      else: []
  end

  def sso_provider(provider) do
    %{
      provider_id: provider.provider_id,
      issuer: provider.issuer,
      domain: provider.domain,
      domain_verified: provider.domain_verified,
      organization_id: provider.organization_id,
      created_at: provider.inserted_at
    }
  end

  def scim_connection(connection) do
    %{
      id: to_string(connection.id),
      name: connection.name,
      organization_id: connection.organization_id,
      provider_id: connection.provider_id,
      status: connection.status,
      last_used_at: connection.last_used_at,
      created_at: connection.inserted_at
    }
  end

  ## Service accounts

  def service_accounts(ctx, offset) do
    if model?(ctx, :service_account) do
      query =
        from(s in Store.module(ctx, :service_account),
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: ^(@page + 1),
          offset: ^offset
        )

      ctx |> Store.list(:service_account, query) |> Enum.map(&service_account/1)
    else
      []
    end
  end

  def find_service_account(ctx, id), do: safe_get(ctx, :service_account, id)

  defp service_account(account) do
    %{
      id: to_string(account.id),
      name: account.name,
      description: account.description,
      user_id: account.user_id && to_string(account.user_id),
      organization_id: account.organization_id,
      role: account.role,
      disabled: account.disabled,
      expires_at: account.expires_at,
      last_used_at: account.last_used_at,
      oauth_client: not is_nil(account.oauth_client_id),
      created_at: account.inserted_at
    }
  end

  ## Events

  def events(ctx, filters, offset) do
    if enabled?(ctx, AuditLog) do
      %{events: events, total: total} =
        AuditLog.list_events(
          ctx.config.auth,
          Keyword.merge(filters, limit: @page, offset: offset)
        )

      %{events: events, total: total}
    else
      %{events: [], total: 0}
    end
  end
end
