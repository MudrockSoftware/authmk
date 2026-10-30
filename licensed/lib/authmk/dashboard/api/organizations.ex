defmodule Authmk.Dashboard.API.Organizations do
  @moduledoc false
  # Organizations (with Authmk.Plugins.Organization): the list, one
  # organization's page, and changes to it, its members, teams and
  # invitations. Changes go through the plugin's server-side functions, so
  # its rules hold (an organization keeps an owner, roles must exist,
  # limits), without asking the admin to be a member. They need the Admin
  # permissions `organization: create, update, delete`.

  alias Authmk.{Context, Email, Error, Store}
  alias Authmk.Dashboard.{Data, Reply}
  alias Authmk.Dashboard.Data.{Fields, Organizations}
  alias Authmk.Plugins.Organization
  alias Authmk.Plugins.Organization.Access, as: OrganizationAccess

  def route(conn, path, ctx, admin) do
    if Data.enabled?(ctx, Organization),
      do: organizations(conn, conn.method, path, ctx, admin),
      else: Reply.not_found(conn)
  end

  defp organizations(conn, "GET", [], ctx, _admin) do
    rows = Organizations.list(ctx, Reply.param(conn, "search"), Reply.offset(conn))
    Reply.page(conn, rows, :organizations)
  end

  defp organizations(conn, "GET", ["options"], ctx, _admin),
    do: Reply.json(conn, 200, %{organizations: Organizations.options(ctx)})

  defp organizations(conn, "POST", [], ctx, admin), do: create(conn, ctx, admin)

  defp organizations(conn, method, [id | path], ctx, admin) do
    case Organizations.find(ctx, id) do
      nil -> Reply.not_found(conn, "organization")
      organization -> on_organization(conn, method, path, ctx, admin, organization)
    end
  end

  defp on_organization(conn, "GET", [], ctx, _admin, organization),
    do: Reply.json(conn, 200, Organizations.detail(ctx, organization))

  defp on_organization(conn, "POST", ["update"], ctx, admin, organization) do
    case attrs(ctx, conn) do
      {:ok, attrs} ->
        change(conn, ctx, admin, organization, "organization.updated", fn auth ->
          Organization.update_organization(auth, organization.id, attrs)
        end)

      {:error, message} ->
        invalid(conn, message)
    end
  end

  defp on_organization(conn, "POST", ["delete"], ctx, admin, organization) do
    event = {"organization.deleted", details(organization)}

    Reply.permitted(conn, ctx, admin, %{organization: [:delete]}, event, fn ->
      ok(Organization.delete_organization(ctx.config.auth, organization.id))
    end)
  end

  defp on_organization(conn, "POST", ["members"], ctx, admin, organization) do
    role = Reply.param(conn, "role")

    # The plugin's add_member/4 takes any role: only the organization's here.
    if known_role?(ctx, organization, role) do
      with_user(conn, ctx, Reply.param(conn, "email"), fn user ->
        add_member(conn, ctx, admin, organization, user, role)
      end)
    else
      invalid(conn, "That role doesn't exist in this organization.")
    end
  end

  defp on_organization(conn, "POST", ["members", user_id, "role"], ctx, admin, organization) do
    role = Reply.param(conn, "role")
    metadata = [user_id: user_id, role: role]

    change(conn, ctx, admin, organization, "member.role_set", metadata, fn auth ->
      Organization.set_member_role(auth, organization.id, user_id, role)
    end)
  end

  defp on_organization(conn, "POST", ["members", user_id, "remove"], ctx, admin, organization) do
    change(conn, ctx, admin, organization, "member.removed", [user_id: user_id], fn auth ->
      Organization.remove_member(auth, organization.id, user_id)
    end)
  end

  defp on_organization(conn, "POST", ["teams"], ctx, admin, organization) do
    attrs = %{"name" => Reply.param(conn, "name")}

    change(conn, ctx, admin, organization, "team.created", fn auth ->
      Organization.create_team(auth, organization.id, attrs)
    end)
  end

  defp on_organization(conn, "POST", ["teams", team_id | path], ctx, admin, organization) do
    case team(ctx, organization, team_id) do
      nil -> Reply.not_found(conn, "team")
      team -> on_team(conn, path, ctx, admin, organization, team)
    end
  end

  defp on_organization(conn, "POST", ["invitations"], ctx, admin, organization) do
    email = Email.normalize(Reply.param(conn, "email") || "")
    role = Reply.param(conn, "role")
    opts = [team_id: Reply.param(conn, "team_id")]

    change(conn, ctx, admin, organization, "invitation.created", [role: role], fn auth ->
      Organization.invite_member(auth, organization.id, email, role, admin.id, opts)
    end)
  end

  defp on_organization(conn, "POST", ["invitations", id, "cancel"], ctx, admin, organization) do
    case invitation(ctx, organization, id) do
      nil ->
        Reply.not_found(conn, "invitation")

      invitation ->
        metadata = [invitation_id: id]

        change(conn, ctx, admin, organization, "invitation.canceled", metadata, fn auth ->
          Organization.cancel_invitation(auth, invitation.id)
        end)
    end
  end

  defp on_organization(conn, _method, _path, _ctx, _admin, _organization),
    do: Reply.not_found(conn)

  defp add_member(conn, ctx, admin, organization, user, role) do
    metadata = [user_id: user.id, role: role]

    change(conn, ctx, admin, organization, "member.added", metadata, fn auth ->
      Organization.add_member(auth, organization.id, user.id, role)
    end)
  end

  defp known_role?(ctx, organization, role) do
    ctx = Context.put_private(ctx, :organization_plugin, Organization)
    is_binary(role) and OrganizationAccess.valid_role?(ctx, organization, role)
  end

  defp on_team(conn, ["update"], ctx, admin, organization, team) do
    attrs = %{"name" => Reply.param(conn, "name")}

    change(conn, ctx, admin, organization, "team.updated", [team_id: team.id], fn auth ->
      Organization.update_team(auth, team.id, attrs)
    end)
  end

  defp on_team(conn, ["remove"], ctx, admin, organization, team) do
    change(conn, ctx, admin, organization, "team.removed", [team_id: team.id], fn auth ->
      Organization.remove_team(auth, team.id)
    end)
  end

  defp on_team(conn, ["members"], ctx, admin, organization, team) do
    user_id = Reply.param(conn, "user_id")
    metadata = [team_id: team.id, user_id: user_id]

    change(conn, ctx, admin, organization, "team_member.added", metadata, fn auth ->
      Organization.add_team_member(auth, team.id, user_id)
    end)
  end

  defp on_team(conn, ["members", user_id, "remove"], ctx, admin, organization, team) do
    metadata = [team_id: team.id, user_id: user_id]

    change(conn, ctx, admin, organization, "team_member.removed", metadata, fn auth ->
      Organization.remove_team_member(auth, team.id, user_id)
    end)
  end

  defp on_team(conn, _path, _ctx, _admin, _organization, _team), do: Reply.not_found(conn)

  # A new organization needs its owner: an existing user, by email.
  defp create(conn, ctx, admin) do
    case attrs(ctx, conn) do
      {:ok, attrs} ->
        with_user(
          conn,
          ctx,
          Reply.param(conn, "owner_email"),
          &create(conn, ctx, admin, attrs, &1)
        )

      {:error, message} ->
        invalid(conn, message)
    end
  end

  defp create(conn, ctx, admin, attrs, owner) do
    event = {"organization.created", %{metadata: %{owner_id: to_string(owner.id)}}}

    Reply.permitted(conn, ctx, admin, %{organization: [:create]}, event, fn ->
      case Organization.create_organization(ctx.config.auth, attrs, owner.id) do
        {:ok, organization} -> {:ok, %{id: to_string(organization.id)}}
        {:error, error} -> {:error, error}
      end
    end)
  end

  # Name, slug, logo and the app's own fields: only those given.
  defp attrs(ctx, conn) do
    body = Reply.body(conn)

    with {:ok, fields} <- Fields.cast(ctx, :organization, body["fields"] || %{}),
         do: {:ok, Map.merge(fields, Map.take(body, ["name", "slug", "logo"]))}
  end

  defp change(conn, ctx, admin, organization, event, metadata \\ [], fun) do
    details = Map.put(details(organization), :metadata, Map.new(metadata, &stringify/1))

    Reply.permitted(conn, ctx, admin, %{organization: [:update]}, {event, details}, fn ->
      ok(fun.(ctx.config.auth))
    end)
  end

  defp details(organization), do: %{organization_id: organization.id, metadata: %{}}

  defp stringify({key, value}) when is_binary(value) or is_nil(value), do: {key, value}
  defp stringify({key, value}), do: {key, to_string(value)}

  defp ok({:ok, _result}), do: :ok
  defp ok({:error, %Error{}} = error), do: error

  defp with_user(conn, ctx, email, fun) do
    case email && Store.get_by(ctx, :user, email: Email.normalize(email)) do
      nil -> invalid(conn, "No user has that email.")
      user -> fun.(user)
    end
  end

  defp team(ctx, organization, id) do
    case Data.safe_get(ctx, :team, id) do
      %{organization_id: organization_id} = team when organization_id == organization.id -> team
      _other -> nil
    end
  end

  defp invitation(ctx, organization, id) do
    case Data.safe_get(ctx, :invitation, id) do
      %{organization_id: organization_id} = invitation
      when organization_id == organization.id ->
        invitation

      _other ->
        nil
    end
  end

  defp invalid(conn, message),
    do: Reply.from_error(conn, Error.custom(:invalid_request, 400, message))
end
