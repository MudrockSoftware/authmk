defmodule Authmk.Plugins.SCIM.Groups do
  @moduledoc false
  # /scim/v2/Groups. Groups hold users of the same connection. With
  # `group_roles` and `Authmk.Plugins.Organization`, a group gives its
  # members an organization role, reconciled whenever membership changes.

  import Ecto.Query

  alias Authmk.{Context, Store}
  alias Authmk.Plugins.Organization
  alias Authmk.Plugins.SCIM.{Config, Errors, Lists, Patch}

  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @attributes %{"displayname" => {:root, :display_name}, "externalid" => {:root, :external_id}}

  def list(%Context{raw_params: params} = ctx) do
    connection = ctx.private.scim_connection

    query =
      from(g in Store.module(ctx, :scim_group),
        as: :root,
        where: g.scim_connection_id == ^connection.id,
        order_by: g.inserted_at
      )

    case Lists.page(ctx, :scim_group, query, params, @attributes) do
      {:ok, total, start, groups} ->
        Errors.json(ctx, 200, Lists.response(total, start, Enum.map(groups, &render(ctx, &1))))

      {:error, detail} ->
        Errors.error(ctx, 400, "invalidFilter", detail)
    end
  end

  def get(ctx) do
    case find(ctx) do
      nil -> Errors.not_found(ctx)
      group -> Errors.json(ctx, 200, render(ctx, group))
    end
  end

  def create(%Context{raw_params: params} = ctx) do
    connection = ctx.private.scim_connection

    with {:ok, attrs} <- parse(params),
         :ok <- unique_name(ctx, connection, attrs.display_name, nil),
         {:ok, members} <- members(ctx, connection, attrs.members),
         {:ok, group} <- Store.insert(ctx, :scim_group, group_attrs(ctx, attrs, connection)) do
      :ok = set_members(ctx, group, members, [])
      Errors.json(ctx, 201, render(ctx, group))
    else
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  def replace(%Context{raw_params: params} = ctx) do
    with %{} = group <- find(ctx) || :not_found,
         {:ok, attrs} <- parse(params) do
      save(ctx, group, attrs)
    else
      :not_found -> Errors.not_found(ctx)
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  def patch(%Context{raw_params: params} = ctx) do
    with %{} = group <- find(ctx) || :not_found,
         {:ok, attrs} <- Patch.apply_group(current(ctx, group), params) do
      save(ctx, group, attrs)
    else
      :not_found -> Errors.not_found(ctx)
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  def delete(ctx) do
    case find(ctx) do
      nil ->
        Errors.not_found(ctx)

      group ->
        old = member_links(ctx, group)
        {:ok, _group} = Store.delete(ctx, :scim_group, group)
        :ok = reconcile(ctx, old)
        {:html, 204, "", ctx}
    end
  end

  defp save(ctx, group, attrs) do
    connection = ctx.private.scim_connection

    with :ok <- unique_name(ctx, connection, attrs.display_name, group.id),
         {:ok, members} <- members(ctx, connection, attrs.members),
         {:ok, group} <-
           Store.update(ctx, :scim_group, group, group_attrs(ctx, attrs, connection)) do
      :ok = set_members(ctx, group, members, member_links(ctx, group))
      Errors.json(ctx, 200, render(ctx, group))
    else
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  defp find(%Context{raw_params: %{"id" => id}} = ctx) do
    Store.get_by(ctx, :scim_group, id: id, scim_connection_id: ctx.private.scim_connection.id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp parse(%{"displayName" => name} = params) when is_binary(name) and name != "" do
    with {:ok, members} <- Patch.member_ids(params["members"] || []),
         do: {:ok, %{display_name: name, external_id: params["externalId"], members: members}}
  end

  defp parse(_params), do: {:scim_error, 400, "invalidValue", "displayName is required"}

  defp current(ctx, group) do
    %{
      display_name: group.display_name,
      external_id: group.external_id,
      members: Enum.map(member_links(ctx, group), &to_string(&1.id))
    }
  end

  defp group_attrs(ctx, attrs, connection) do
    role =
      case Config.opts(ctx)[:group_roles] do
        nil -> nil
        roles -> roles.(attrs.display_name)
      end

    %{
      scim_connection_id: connection.id,
      display_name: attrs.display_name,
      external_id: attrs.external_id,
      role: role
    }
  end

  defp unique_name(ctx, connection, name, except_id) do
    query =
      from(g in Store.module(ctx, :scim_group),
        where:
          g.scim_connection_id == ^connection.id and
            fragment("lower(?)", g.display_name) == ^String.downcase(name)
      )

    query = if except_id, do: where(query, [g], g.id != ^except_id), else: query

    if Store.count(ctx, :scim_group, query) == 0,
      do: :ok,
      else: {:scim_error, 409, "uniqueness", "displayName is taken"}
  end

  # Members are this connection's users, by their SCIM ids.
  defp members(_ctx, _connection, []), do: {:ok, []}

  defp members(ctx, connection, ids) do
    links =
      Store.list(
        ctx,
        :scim_user,
        from(l in Store.module(ctx, :scim_user),
          where:
            l.scim_connection_id == ^connection.id and is_nil(l.deprovisioned_at) and
              l.id in ^ids
        )
      )

    if length(links) == length(Enum.uniq(ids)),
      do: {:ok, links},
      else: {:scim_error, 400, "invalidValue", "Unknown member"}
  rescue
    Ecto.Query.CastError -> {:scim_error, 400, "invalidValue", "Unknown member"}
  end

  defp set_members(ctx, group, links, old) do
    _count = Store.delete_all(ctx, :scim_group_member, scim_group_id: group.id)

    Enum.each(
      links,
      &({:ok, _member} =
          Store.insert(ctx, :scim_group_member, %{scim_group_id: group.id, scim_user_id: &1.id}))
    )

    reconcile(ctx, Enum.uniq_by(old ++ links, & &1.id))
  end

  defp member_links(ctx, group) do
    query =
      from(l in Store.module(ctx, :scim_user),
        join: m in ^Store.module(ctx, :scim_group_member),
        on: m.scim_user_id == l.id,
        where: m.scim_group_id == ^group.id
      )

    Store.list(ctx, :scim_user, query)
  end

  # Each affected user gets the best role their groups give, or the default.
  defp reconcile(%Context{config: config} = ctx, links) do
    connection = ctx.private.scim_connection

    if connection.organization_id && Organization in Enum.map(config.plugins, &elem(&1, 0)) do
      Enum.each(links, fn link ->
        _result =
          Organization.set_member_role(
            config.auth,
            connection.organization_id,
            link.user_id,
            role_for(ctx, link)
          )
      end)
    end

    :ok
  end

  defp role_for(ctx, link) do
    opts = Config.opts(ctx)

    roles =
      Store.list(
        ctx,
        :scim_group,
        from(g in Store.module(ctx, :scim_group),
          join: m in ^Store.module(ctx, :scim_group_member),
          on: m.scim_group_id == g.id,
          where: m.scim_user_id == ^link.id and not is_nil(g.role),
          select: g.role
        )
      )

    Enum.find(opts[:role_priority], opts[:default_role], &(&1 in roles))
  end

  defp render(ctx, group) do
    members =
      for link <- member_links(ctx, group),
          do: %{value: to_string(link.id), display: link.user_name}

    %{
      schemas: [@group_schema],
      id: to_string(group.id),
      displayName: group.display_name,
      externalId: group.external_id,
      members: members,
      meta: Lists.meta(ctx, "Group", "/scim/v2/Groups/", group)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
