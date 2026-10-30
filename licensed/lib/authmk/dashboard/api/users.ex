defmodule Authmk.Dashboard.API.Users do
  @moduledoc false
  # Users: the list, one user's page, and what admins do to them. Changes
  # run through Authmk.Plugins.Admin's endpoints where it has one, so its
  # rules hold here too: permissions by role, nobody bans or removes
  # themselves, and nobody manages a user stronger than they are
  # (`Admin.can_manage?/3`).

  alias Authmk.Dashboard.{Access, Reply}
  alias Authmk.Dashboard.Data.{Fields, Users}
  alias Authmk.{Email, Error, Store}
  alias Authmk.Plugins.Admin

  def route(%Plug.Conn{method: "GET"} = conn, [], ctx, _admin) do
    filters = [
      search: Reply.param(conn, "search"),
      status: Reply.param(conn, "status"),
      organization_id: Reply.param(conn, "organization_id")
    ]

    Reply.page(conn, Users.list(ctx, filters, Reply.offset(conn)), :users)
  end

  def route(%Plug.Conn{method: "POST"} = conn, [], ctx, admin), do: create(conn, ctx, admin)

  def route(conn, [id | path], ctx, admin) do
    case Users.find(ctx, id) do
      nil -> Reply.not_found(conn, "user")
      user -> on_user(conn, conn.method, path, ctx, admin, user)
    end
  end

  defp on_user(conn, "GET", [], ctx, _admin, user),
    do: Reply.json(conn, 200, Users.detail(ctx, user))

  defp on_user(conn, "POST", ["update"], ctx, admin, user), do: update(conn, ctx, admin, user)

  defp on_user(conn, "POST", ["set-role"], ctx, admin, user) do
    role = Reply.param(conn, "role")

    endpoint(conn, ctx, admin, user, :admin_set_role, %{"role" => role}, "user.role_set",
      role: role
    )
  end

  # The password itself goes nowhere but to the hasher.
  defp on_user(conn, "POST", ["set-password"], ctx, admin, user) do
    params = %{"new_password" => Reply.param(conn, "password")}
    endpoint(conn, ctx, admin, user, :admin_set_user_password, params, "user.password_set")
  end

  defp on_user(conn, "POST", ["ban"], ctx, admin, user) do
    params = %{
      "ban_reason" => Reply.param(conn, "reason"),
      "ban_expires_in" => Reply.param(conn, "expires_in")
    }

    endpoint(conn, ctx, admin, user, :admin_ban_user, params, "user.banned",
      expires_in: params["ban_expires_in"]
    )
  end

  defp on_user(conn, "POST", ["unban"], ctx, admin, user),
    do: endpoint(conn, ctx, admin, user, :admin_unban_user, %{}, "user.unbanned")

  defp on_user(conn, "POST", ["revoke-sessions"], ctx, admin, user),
    do: endpoint(conn, ctx, admin, user, :admin_revoke_user_sessions, %{}, "sessions.revoked")

  defp on_user(conn, "POST", ["sessions", session_id, "revoke"], ctx, admin, user) do
    params = %{"session_id" => session_id}

    endpoint(conn, ctx, admin, user, :admin_revoke_user_session, params, "session.revoked",
      session_id: session_id
    )
  end

  # Signs the admin in as the user; the dashboard then opens the app.
  defp on_user(conn, "POST", ["impersonate"], ctx, admin, user),
    do: endpoint(conn, ctx, admin, user, :admin_impersonate_user, %{}, "user.impersonated")

  defp on_user(conn, "POST", ["delete"], ctx, admin, user),
    do: endpoint(conn, ctx, admin, user, :admin_remove_user, %{}, "user.deleted")

  defp on_user(conn, "POST", ["verify-email"], ctx, admin, user) do
    managed(conn, ctx, admin, user, %{user: [:update]}, "user.email_verified", fn ->
      with {:ok, _user} <- Store.update(ctx, :user, user, %{email_verified: true}), do: :ok
    end)
  end

  # For a user who lost their device: two-factor off, its secrets gone.
  defp on_user(conn, "POST", ["disable-two-factor"], ctx, admin, user) do
    managed(conn, ctx, admin, user, %{user: [:update]}, "user.two_factor_disabled", fn ->
      _removed =
        if Map.has_key?(ctx.config.schema.models, :two_factor),
          do: Store.delete_all(ctx, :two_factor, user_id: user.id)

      with {:ok, _user} <- Store.update(ctx, :user, user, %{two_factor_enabled: false}), do: :ok
    end)
  end

  defp on_user(conn, "POST", ["accounts", account_id, "unlink"], ctx, admin, user),
    do: unlink(conn, ctx, admin, user, account_id)

  defp on_user(conn, _method, _path, _ctx, _admin, _user), do: Reply.not_found(conn)

  defp create(conn, ctx, admin) do
    case fields(ctx, conn) do
      {:ok, fields} ->
        params = %{
          "email" => Reply.param(conn, "email"),
          "name" => Reply.param(conn, "name"),
          "password" => Reply.param(conn, "password"),
          "role" => Reply.param(conn, "role"),
          "data" => fields
        }

        Reply.run_endpoint(conn, ctx, admin, :admin_create_user, params, {"user.created", %{}})

      {:error, message} ->
        invalid(conn, message)
    end
  end

  # Name, email, picture and the app's own fields. A new email isn't
  # verified: the admin verifies it on purpose, or the user does.
  defp update(conn, ctx, admin, user) do
    with {:ok, fields} <- fields(ctx, conn),
         {:ok, core} <- core_changes(conn, user) do
      data = Map.merge(fields, core)
      changed = data |> Map.keys() |> Enum.sort()

      endpoint(conn, ctx, admin, user, :admin_update_user, %{"data" => data}, "user.updated",
        fields: changed
      )
    else
      {:error, message} -> invalid(conn, message)
    end
  end

  defp core_changes(conn, user) do
    body = Reply.body(conn)
    core = Map.take(body, ["name", "image"])

    case body["email"] do
      nil ->
        {:ok, core}

      email ->
        email = Email.normalize(to_string(email))

        cond do
          not Email.valid?(email) -> {:error, "That email isn't valid."}
          email == user.email -> {:ok, core}
          true -> {:ok, Map.merge(core, %{"email" => email, "email_verified" => false})}
        end
    end
  end

  defp fields(ctx, conn), do: Fields.cast(ctx, :user, Reply.body(conn)["fields"] || %{})

  # Refused when it's the user's last way to sign in.
  defp unlink(conn, ctx, admin, user, account_id) do
    accounts = Users.accounts(ctx, user)

    case Enum.find(accounts, &(to_string(&1.id) == account_id)) do
      nil ->
        Reply.not_found(conn, "linked account")

      _last when length(accounts) == 1 ->
        invalid(conn, "That's the user's only way to sign in.")

      account ->
        managed(conn, ctx, admin, user, %{user: [:update]}, "account.unlinked", fn ->
          delete_account(ctx, account)
        end)
    end
  end

  defp delete_account(ctx, account) do
    case Store.delete(ctx, :account, account) do
      {:ok, _account} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp endpoint(conn, ctx, admin, user, name, params, event, metadata \\ []) do
    params = Map.put(params, "user_id", to_string(user.id))
    details = %{user_id: user.id, metadata: Map.new(metadata)}
    Reply.run_endpoint(conn, ctx, admin, name, params, {event, details})
  end

  # Actions without an Admin endpoint check the same things it would.
  defp managed(conn, ctx, admin, user, permissions, event, fun) do
    if Access.can?(ctx, admin, permissions) and Admin.can_manage?(ctx, admin, user),
      do: Reply.permitted(conn, ctx, admin, permissions, {event, %{user_id: user.id}}, fun),
      else: Reply.forbidden(conn)
  end

  defp invalid(conn, message),
    do: Reply.from_error(conn, Error.custom(:invalid_request, 400, message))
end
