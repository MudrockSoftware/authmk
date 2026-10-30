defmodule Authmk.Dashboard.Data.Users do
  @moduledoc false
  # Users for the dashboard: the list (search and filters) and everything
  # about one user.

  import Ecto.Query

  alias Authmk.Dashboard.Data
  alias Authmk.Dashboard.Data.{Fields, Permissions}
  alias Authmk.Plugins.AuditLog
  alias Authmk.{SessionStore, Store}

  @doc """
  Users, newest first. `filters`: `:search` (in email or name), `:status`
  (`"banned"`, `"unverified"`, `"two_factor"`), `:organization_id`.
  """
  def list(ctx, filters, offset) do
    from(u in Store.module(ctx, :user),
      order_by: [desc: u.inserted_at, desc: u.id],
      limit: ^(Data.page_size() + 1),
      offset: ^offset
    )
    |> filter(ctx, filters)
    |> then(&Store.list(ctx, :user, &1))
    |> Enum.map(&Data.user/1)
  end

  @doc "The users matching `filters`, as a query: for lists and exports."
  def filter(query, ctx, filters) do
    query
    |> search(filters[:search])
    |> status(ctx, filters[:status])
    |> Data.in_organization(ctx, filters[:organization_id])
  end

  defp search(query, search) do
    case String.trim(search || "") do
      "" ->
        query

      term ->
        pattern = "%" <> Data.escape_like(String.downcase(term)) <> "%"

        where(
          query,
          [u],
          fragment("lower(?) LIKE ? ESCAPE '!'", u.email, ^pattern) or
            fragment("lower(?) LIKE ? ESCAPE '!'", u.name, ^pattern)
        )
    end
  end

  defp status(query, ctx, "banned") do
    if Data.field?(ctx, :user, :banned),
      do: where(query, [u], u.banned == true),
      else: none(query)
  end

  defp status(query, _ctx, "unverified"), do: where(query, [u], u.email_verified == false)

  defp status(query, ctx, "two_factor") do
    if Data.field?(ctx, :user, :two_factor_enabled),
      do: where(query, [u], u.two_factor_enabled == true),
      else: none(query)
  end

  defp status(query, _ctx, _any), do: query

  defp none(query), do: where(query, false)

  def find(ctx, id), do: Data.safe_get(ctx, :user, id)

  @doc "Everything about one user, for their page."
  def detail(ctx, user) do
    %{
      user: Map.put(Data.user(user), :fields, Fields.values(ctx, :user, user)),
      fields: Fields.definitions(ctx, :user),
      sessions: ctx |> SessionStore.list(user.id) |> Enum.map(&session/1),
      accounts: Enum.map(accounts(ctx, user), &account/1),
      access: Permissions.of(ctx, user),
      api_keys: api_keys(ctx, user),
      two_factor: two_factor(ctx, user),
      subscriptions: subscriptions(ctx, user),
      events:
        if(Data.enabled?(ctx, AuditLog),
          do: AuditLog.list_events(ctx.config.auth, user_id: user.id, limit: 20).events,
          else: []
        )
    }
  end

  def accounts(ctx, user) do
    Store.list(
      ctx,
      :account,
      from(a in Store.module(ctx, :account), where: a.user_id == ^user.id, limit: 100)
    )
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

  defp account(account) do
    %{
      id: to_string(account.id),
      provider: account.provider_id,
      account_id: account.account_id,
      created_at: account.inserted_at
    }
  end

  defp api_keys(ctx, user) do
    for key <- by_user(ctx, :api_key, user) do
      %{
        id: to_string(key.id),
        name: key.name,
        start: key.start,
        prefix: key.prefix,
        enabled: key.enabled,
        organization_id: key.organization_id,
        permissions: decode(key.permissions),
        expires_at: key.expires_at,
        last_used_at: key.last_request_at,
        created_at: key.inserted_at
      }
    end
  end

  # Which second factors the user has set up. Never their secrets.
  defp two_factor(ctx, user) do
    %{
      enabled: Map.get(user, :two_factor_enabled) == true,
      authenticator_app: by_user(ctx, :two_factor, user) != [],
      passkeys:
        for(
          passkey <- by_user(ctx, :passkey, user),
          do: %{id: to_string(passkey.id), name: passkey.name, created_at: passkey.inserted_at}
        ),
      phone_number:
        if(Data.field?(ctx, :user, :phone_number_verified),
          do: Map.get(user, :phone_number_verified) == true
        )
    }
  end

  defp subscriptions(ctx, user) do
    if Data.model?(ctx, :subscription),
      do:
        Store.list(
          ctx,
          :subscription,
          from(s in Store.module(ctx, :subscription),
            where: s.reference_type == "user" and s.reference_id == ^to_string(user.id),
            order_by: [desc: s.inserted_at],
            limit: 20
          )
        )
        |> Enum.map(&Data.subscription/1),
      else: []
  end

  defp by_user(ctx, model, user) do
    if Data.model?(ctx, model),
      do:
        Store.list(
          ctx,
          model,
          from(r in Store.module(ctx, model), where: r.user_id == ^user.id, limit: 100)
        ),
      else: []
  end

  defp decode(nil), do: nil

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, value} -> value
      {:error, _invalid} -> nil
    end
  end
end
