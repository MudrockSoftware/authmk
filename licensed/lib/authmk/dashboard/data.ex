defmodule Authmk.Dashboard.Data do
  @moduledoc false
  # The dashboard's reads, as JSON-ready maps, through authmk's store. Every
  # query is bounded, and works on SQLite, PostgreSQL, MySQL and MariaDB.

  import Ecto.Query

  alias Authmk.{Context, SessionStore, Store}
  alias Authmk.Plugins.AuditLog

  @page 50

  def page_size, do: @page

  def enabled?(%Context{config: config}, plugin),
    do: plugin in Enum.map(config.plugins, &elem(&1, 0))

  def model?(%Context{config: config}, model), do: Map.has_key?(config.schema.models, model)

  ## Overview

  def overview(ctx) do
    %{
      totals: totals(ctx),
      sign_ups: per_day(ctx, :user, 30),
      sign_ins: sign_ins(ctx),
      sign_in_methods: sign_in_methods(ctx),
      recent_users: ctx |> users("", 0) |> Enum.take(5)
    }
  end

  defp totals(ctx) do
    users = from(u in Store.module(ctx, :user))
    now = DateTime.utc_now()

    %{
      users: Store.count(ctx, :user, users),
      verified_users: Store.count(ctx, :user, where(users, [u], u.email_verified == true)),
      two_factor_users:
        if(field?(ctx, :user, :two_factor_enabled),
          do: Store.count(ctx, :user, where(users, [u], u.two_factor_enabled == true))
        ),
      organizations:
        if(model?(ctx, :organization),
          do: Store.count(ctx, :organization, from(o in Store.module(ctx, :organization)))
        ),
      active_sessions:
        Store.count(
          ctx,
          :session,
          from(s in Store.module(ctx, :session), where: s.expires_at > ^now)
        )
    }
  end

  # From the audit log when it's on: sessions end, events stay.
  defp sign_ins(ctx) do
    if enabled?(ctx, AuditLog),
      do: per_day(ctx, :audit_event, 30, dynamic([e], e.event == "session.created")),
      else: per_day(ctx, :session, 30)
  end

  defp sign_in_methods(ctx) do
    query =
      from(a in Store.module(ctx, :account),
        group_by: a.provider_id,
        select: {a.provider_id, count(a.id)},
        order_by: [desc: count(a.id)],
        limit: 12
      )

    for {provider, count} <- Store.list(ctx, :account, query),
        do: %{provider: provider, count: count}
  end

  # Counts per day (oldest first): one bounded count per day.
  defp per_day(ctx, model, days, condition \\ nil) do
    today = Date.utc_today()

    for offset <- (days - 1)..0//-1 do
      day = Date.add(today, -offset)
      from = DateTime.new!(day, ~T[00:00:00])

      query =
        from(r in Store.module(ctx, model),
          where: r.inserted_at >= ^from and r.inserted_at < ^DateTime.add(from, 86_400)
        )

      query = if condition, do: where(query, ^condition), else: query
      %{day: Date.to_iso8601(day), count: Store.count(ctx, model, query)}
    end
  end

  ## Users

  @doc "Users whose email or name contains `search`, newest first."
  def users(ctx, search, offset) do
    query =
      from(u in Store.module(ctx, :user),
        order_by: [desc: u.inserted_at, desc: u.id],
        limit: @page + 1,
        offset: ^offset
      )

    query =
      case String.trim(search || "") do
        "" ->
          query

        term ->
          pattern = "%" <> escape(String.downcase(term)) <> "%"

          where(
            query,
            [u],
            fragment("lower(?) LIKE ? ESCAPE '!'", u.email, ^pattern) or
              fragment("lower(?) LIKE ? ESCAPE '!'", u.name, ^pattern)
          )
      end

    ctx |> Store.list(:user, query) |> Enum.map(&user/1)
  end

  def find_user(ctx, id) do
    Store.get_by(ctx, :user, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  def user_detail(ctx, user) do
    %{
      user: user(user),
      sessions: ctx |> SessionStore.list(user.id) |> Enum.map(&session/1),
      accounts:
        Enum.map(
          Store.list(
            ctx,
            :account,
            from(a in Store.module(ctx, :account), where: a.user_id == ^user.id)
          ),
          &account/1
        ),
      organizations: memberships(ctx, user),
      events:
        if(enabled?(ctx, AuditLog),
          do: AuditLog.list_events(ctx.config.auth, user_id: user.id, limit: 20).events,
          else: []
        )
    }
  end

  defp memberships(ctx, user) do
    if model?(ctx, :member) do
      query =
        from(m in Store.module(ctx, :member),
          join: o in ^Store.module(ctx, :organization),
          on: o.id == m.organization_id,
          where: m.user_id == ^user.id,
          select: {o, m.role}
        )

      for {organization, role} <- Store.list(ctx, :member, query),
          do: %{
            id: to_string(organization.id),
            name: organization.name,
            slug: organization.slug,
            role: role
          }
    else
      []
    end
  end

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
      two_factor_enabled: Map.get(user, :two_factor_enabled),
      last_sign_in_at: Map.get(user, :last_sign_in_at),
      created_at: user.inserted_at
    }
  end

  defp session(session) do
    %{
      id: to_string(session.id),
      ip_address: session.ip_address,
      user_agent: session.user_agent,
      created_at: session.inserted_at,
      expires_at: session.expires_at,
      impersonated_by:
        Map.get(session, :impersonated_by_id) && to_string(session.impersonated_by_id)
    }
  end

  defp account(account), do: %{provider: account.provider_id, created_at: account.inserted_at}

  ## Organizations

  def organizations(ctx, offset) do
    if model?(ctx, :organization) do
      member_counts =
        from(m in Store.module(ctx, :member),
          group_by: m.organization_id,
          select: {m.organization_id, count(m.id)}
        )

      counts =
        ctx
        |> Store.list(:member, member_counts)
        |> Map.new(fn {id, count} -> {to_string(id), count} end)

      query =
        from(o in Store.module(ctx, :organization),
          order_by: [desc: o.inserted_at, desc: o.id],
          limit: @page + 1,
          offset: ^offset
        )

      for organization <- Store.list(ctx, :organization, query) do
        organization
        |> organization()
        |> Map.put(:members, Map.get(counts, to_string(organization.id), 0))
      end
    else
      []
    end
  end

  def organization_detail(ctx, id) do
    with true <- model?(ctx, :organization),
         %{} = organization <- safe_get(ctx, :organization, id) do
      members =
        from(m in Store.module(ctx, :member),
          join: u in ^Store.module(ctx, :user),
          on: u.id == m.user_id,
          where: m.organization_id == ^organization.id,
          select: {u, m.role, m.inserted_at},
          limit: 500
        )

      %{
        organization: organization(organization),
        members:
          for(
            {user, role, joined} <- Store.list(ctx, :member, members),
            do: %{user: user(user), role: role, joined_at: joined}
          ),
        teams:
          for(
            team <- by_organization(ctx, :team, organization),
            do: %{id: to_string(team.id), name: team.name}
          ),
        invitations:
          for(
            invitation <- by_organization(ctx, :invitation, organization),
            do: %{
              id: to_string(invitation.id),
              email: invitation.email,
              role: invitation.role,
              status: invitation.status,
              expires_at: invitation.expires_at
            }
          ),
        sso_providers:
          Enum.map(by_organization(ctx, :sso_provider, organization), &sso_provider/1),
        scim_connections:
          Enum.map(by_organization(ctx, :scim_connection, organization), &scim_connection/1)
      }
    else
      _missing -> nil
    end
  end

  defp organization(organization) do
    %{
      id: to_string(organization.id),
      name: organization.name,
      slug: organization.slug,
      logo: Map.get(organization, :logo),
      created_at: organization.inserted_at
    }
  end

  defp by_organization(ctx, model, organization) do
    if model?(ctx, model),
      do:
        Store.list(
          ctx,
          model,
          from(r in Store.module(ctx, model),
            where: r.organization_id == ^to_string(organization.id),
            limit: 500
          )
        ),
      else: []
  end

  ## SSO and SCIM

  def sso(ctx) do
    %{
      providers: Enum.map(all(ctx, :sso_provider), &sso_provider/1),
      connections: Enum.map(all(ctx, :scim_connection), &scim_connection/1)
    }
  end

  defp all(ctx, model) do
    if model?(ctx, model),
      do:
        Store.list(
          ctx,
          model,
          from(r in Store.module(ctx, model), order_by: [desc: r.inserted_at], limit: 200)
        ),
      else: []
  end

  defp sso_provider(provider) do
    %{
      provider_id: provider.provider_id,
      issuer: provider.issuer,
      domain: provider.domain,
      domain_verified: provider.domain_verified,
      organization_id: provider.organization_id,
      created_at: provider.inserted_at
    }
  end

  defp scim_connection(connection) do
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

  defp safe_get(ctx, model, id) do
    Store.get_by(ctx, model, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp field?(%Context{config: config}, model, field),
    do: Enum.any?(config.schema.models[model].fields, &(&1.name == field))

  defp escape(term),
    do:
      term |> String.replace("!", "!!") |> String.replace("%", "!%") |> String.replace("_", "!_")
end
