defmodule Authmk.Plugins.Organization.Organizations do
  @moduledoc false
  # Organization endpoints: create, check a slug, update, delete, list,
  # get in full, and the session's active organization.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{Context, CookieCache, Cookies, Input, Serializer, SessionStore, Store}
  alias Authmk.Plugins.Organization.{Access, Config, Errors, Hooks, Members}

  def create(%Context{params: params, user: user} = ctx) do
    opts = Config.opts(ctx)

    with :ok <- check(opts[:allow_user_to_create_organization], :organization_creation_disabled),
         :ok <- under_organization_limit(ctx, user, opts),
         :ok <- slug_free(ctx, params.slug),
         attrs = organization_attrs(ctx),
         {:ok, attrs} <- Hooks.before_event(ctx, :create_organization, attrs),
         {:ok, organization, member} <- insert_with_owner(ctx, attrs, user, opts[:creator_role]),
         {:ok, ctx} <- maybe_activate(ctx, organization, params.keep_current_active_organization) do
      :ok = Hooks.after_event(ctx, :create_organization, organization)

      body =
        Map.put(serialize(ctx, organization), :members, [Serializer.record(ctx, :member, member)])

      {:ok, body, ctx}
    end
  end

  def check_slug(%Context{params: params} = ctx) do
    with :ok <- slug_free(ctx, params.slug), do: {:ok, %{status: true}, ctx}
  end

  def update(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.authorize(ctx, id, organization: [:update]),
         attrs = Input.attrs(%{ctx | raw_params: params.data}, :organization),
         :ok <- slug_free(ctx, attrs["slug"], organization),
         {:ok, attrs} <- Hooks.before_event(ctx, :update_organization, attrs),
         {:ok, organization} <- Store.update(ctx, :organization, organization, attrs) do
      :ok = Hooks.after_event(ctx, :update_organization, organization)
      {:ok, serialize(ctx, organization), ctx}
    end
  end

  def delete(%Context{params: params} = ctx) do
    with {:ok, organization, _member} <-
           Access.authorize(ctx, params.organization_id, organization: [:delete]),
         {:ok, organization} <- Hooks.before_event(ctx, :delete_organization, organization),
         {:ok, _deleted} <- Store.delete(ctx, :organization, organization),
         {:ok, ctx} <- deactivate_if_active(ctx, organization) do
      :ok = Hooks.after_event(ctx, :delete_organization, organization)
      {:ok, %{status: true}, ctx}
    end
  end

  def list(%Context{user: user} = ctx) do
    {:ok, Enum.map(user_organizations(ctx, user), &serialize(ctx, &1)), ctx}
  end

  # The organization with its members and pending invitations (and teams).
  def full(%Context{params: params} = ctx) do
    with {:ok, organization} <- find(ctx, params),
         {:ok, organization, _member} <- Access.member_of(ctx, organization.id) do
      {:ok, full_body(ctx, organization, params.members_limit), ctx}
    end
  end

  # `organization_id: nil` leaves no organization active.
  def set_active(%Context{raw_params: raw, params: params} = ctx) do
    if Map.has_key?(raw, "organization_id") and is_nil(params.organization_id) and
         is_nil(params.organization_slug) do
      with {:ok, ctx} <- set_session(ctx, %{active_organization_id: nil, active_team_id: nil}),
           do: {:ok, nil, ctx}
    else
      with {:ok, organization} <- find(ctx, params),
           {:ok, organization, _member} <- Access.member_of(ctx, organization.id),
           {:ok, ctx} <- activate(ctx, organization) do
        {:ok, full_body(ctx, organization, nil), ctx}
      end
    end
  end

  @doc false
  def activate(ctx, organization),
    do:
      set_session(ctx, %{active_organization_id: to_string(organization.id), active_team_id: nil})

  @doc false
  def serialize(ctx, organization), do: Serializer.record(ctx, :organization, organization)

  defp full_body(ctx, organization, members_limit) do
    invitations =
      ctx
      |> Store.all(:invitation, organization_id: organization.id, status: "pending")
      |> Enum.map(&Serializer.record(ctx, :invitation, &1))

    body =
      ctx
      |> serialize(organization)
      |> Map.put(:members, Members.with_users(ctx, organization, limit: members_limit))
      |> Map.put(:invitations, invitations)

    if Config.opts(ctx)[:teams][:enabled] do
      teams =
        ctx
        |> Store.all(:team, organization_id: organization.id)
        |> Enum.map(&Serializer.record(ctx, :team, &1))

      Map.put(body, :teams, teams)
    else
      body
    end
  end

  # By id or slug, or the active organization.
  defp find(ctx, %{organization_slug: slug}) when is_binary(slug) do
    case Store.get_by(ctx, :organization, slug: slug) do
      nil -> {:error, Errors.error(:organization_not_found)}
      organization -> {:ok, organization}
    end
  end

  defp find(ctx, params) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id) do
      Access.fetch_organization(ctx, id)
    end
  end

  defp insert_with_owner(ctx, attrs, user, creator_role) do
    Store.transaction(ctx, fn ->
      with {:ok, organization} <- Store.insert(ctx, :organization, attrs),
           {:ok, member} <- Members.insert(ctx, organization, user, creator_role) do
        {:ok, {organization, member}}
      end
    end)
    |> case do
      {:ok, {organization, member}} -> {:ok, organization, member}
      error -> error
    end
  end

  defp maybe_activate(ctx, _organization, true), do: {:ok, ctx}
  defp maybe_activate(ctx, organization, _keep_current), do: activate(ctx, organization)

  defp deactivate_if_active(%Context{session: session} = ctx, organization) do
    if Map.get(session, :active_organization_id) == to_string(organization.id),
      do: set_session(ctx, %{active_organization_id: nil, active_team_id: nil}),
      else: {:ok, ctx}
  end

  @doc false
  # The cookie cache carries the session too, so it's refreshed with it.
  def set_session(%Context{session: session} = ctx, attrs) do
    with {:ok, session} <- SessionStore.update(ctx, session, attrs) do
      {:ok, CookieCache.put(%{ctx | session: session}, Cookies.remember_me?(ctx))}
    end
  end

  defp user_organizations(ctx, user) do
    module = Store.module(ctx, :organization)
    member = Store.module(ctx, :member)

    query =
      from(o in module,
        join: m in ^member,
        on: m.organization_id == o.id,
        where: m.user_id == ^user.id,
        order_by: [asc: o.inserted_at]
      )

    Store.list(ctx, :organization, query)
  end

  defp under_organization_limit(ctx, user, opts) do
    case opts[:organization_limit] do
      nil -> :ok
      limit -> check(length(user_organizations(ctx, user)) < limit, :organization_limit_reached)
    end
  end

  defp slug_free(ctx, slug, current \\ nil)
  defp slug_free(_ctx, nil, _current), do: :ok

  defp slug_free(ctx, slug, current) do
    case Store.get_by(ctx, :organization, slug: slug) do
      nil -> :ok
      %{id: id} when not is_nil(current) and id == current.id -> :ok
      _taken -> {:error, Errors.error(:slug_taken)}
    end
  end

  # Request input for the organization's fields (with `additional_fields`),
  # name and slug included.
  defp organization_attrs(%Context{params: params} = ctx) do
    ctx
    |> Input.attrs(:organization)
    |> Map.merge(%{"name" => params.name, "slug" => params.slug})
  end

  defp check(true, _code), do: :ok
  defp check(_false, code), do: {:error, Errors.error(code)}
end
