defmodule Authmk.Plugins.SCIM.Users do
  @moduledoc false
  # /scim/v2/Users. A provisioned user is a `scim_user` link from one
  # connection to an authmk user; its SCIM id is the link's. Deactivated
  # users keep their account but can't sign in (see `SCIM.database_hook/4`),
  # and their sessions end.

  import Ecto.Query

  alias Authmk.{Context, Email, Error, SessionStore, Store}
  alias Authmk.Plugins.Organization
  alias Authmk.Plugins.SCIM.{Config, Errors, Lists, Patch}

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"

  @attributes %{
    "username" => {:link, :user_name},
    "externalid" => {:link, :external_id},
    "active" => {:link, :active},
    "name.givenname" => {:link, :given_name},
    "name.familyname" => {:link, :family_name},
    "displayname" => {:root, :name},
    "emails" => {:root, :email},
    "emails.value" => {:root, :email}
  }

  def list(%Context{raw_params: params} = ctx) do
    connection = ctx.private.scim_connection

    query =
      from(l in Store.module(ctx, :scim_user),
        as: :link,
        join: u in ^Store.module(ctx, :user),
        as: :root,
        on: u.id == l.user_id,
        where: l.scim_connection_id == ^connection.id and is_nil(l.deprovisioned_at),
        order_by: l.inserted_at,
        select: {l, u}
      )

    case Lists.page(ctx, :scim_user, query, params, @attributes) do
      {:ok, total, start, rows} ->
        Errors.json(ctx, 200, Lists.response(total, start, Enum.map(rows, &render(ctx, &1))))

      {:error, detail} ->
        Errors.error(ctx, 400, "invalidFilter", detail)
    end
  end

  def get(ctx) do
    case find(ctx) do
      {link, user} -> Errors.json(ctx, 200, render(ctx, {link, user}))
      nil -> Errors.not_found(ctx)
    end
  end

  def create(%Context{raw_params: params} = ctx) do
    connection = ctx.private.scim_connection

    with {:ok, attrs} <- parse(params),
         :ok <- unique_user_name(ctx, connection, attrs.user_name, nil),
         {:ok, {link, user}} <-
           Store.transaction(ctx, fn -> provision(ctx, connection, attrs) end) do
      Errors.json(ctx, 201, render(ctx, {link, user}))
    else
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
      {:error, {:scim_error, status, type, detail}} -> Errors.error(ctx, status, type, detail)
      {:error, %Error{} = error} -> Errors.error(ctx, 400, "invalidValue", error.message)
    end
  end

  # All or nothing: no half-provisioned user when joining the organization fails.
  defp provision(ctx, connection, attrs) do
    with {:ok, user} <- user_for(ctx, connection, attrs),
         {:ok, link} <- insert_link(ctx, connection, user, attrs),
         :ok <- join_organization(ctx, connection, user) do
      {:ok, {link, user}}
    else
      {:scim_error, _status, _type, _detail} = error -> {:error, error}
      error -> error
    end
  end

  def replace(%Context{raw_params: params} = ctx) do
    with {link, user} <- find(ctx) || :not_found,
         {:ok, attrs} <- parse(params) do
      save(ctx, link, user, attrs)
    else
      :not_found -> Errors.not_found(ctx)
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  def patch(%Context{raw_params: params} = ctx) do
    with {link, user} <- find(ctx) || :not_found,
         {:ok, attrs} <- Patch.apply_user(current(link, user), params) do
      save(ctx, link, user, attrs)
    else
      :not_found -> Errors.not_found(ctx)
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
    end
  end

  def delete(ctx) do
    case find(ctx) do
      nil ->
        Errors.not_found(ctx)

      {link, user} ->
        :ok = remove(ctx, link, user, Config.opts(ctx)[:on_delete])
        {:html, 204, "", ctx}
    end
  end

  defp remove(ctx, link, user, :deactivate) do
    {:ok, _link} =
      Store.update(ctx, :scim_user, link, %{active: false, deprovisioned_at: DateTime.utc_now()})

    :ok = SessionStore.delete_all(ctx, user.id)
  end

  defp remove(ctx, _link, user, :delete) do
    {:ok, _user} = Store.delete(ctx, :user, user)
    :ok
  end

  # PUT and PATCH end here: the whole new state, checked like a create.
  defp save(ctx, link, user, attrs) do
    connection = ctx.private.scim_connection

    with :ok <- unique_user_name(ctx, connection, attrs.user_name, link.id),
         {:ok, user} <- update_user(ctx, user, attrs),
         {:ok, link} <- Store.update(ctx, :scim_user, link, link_attrs(attrs)) do
      if link.active == false, do: :ok = SessionStore.delete_all(ctx, user.id)
      Errors.json(ctx, 200, render(ctx, {link, user}))
    else
      {:scim_error, status, type, detail} -> Errors.error(ctx, status, type, detail)
      {:error, %Error{} = error} -> Errors.error(ctx, 400, "invalidValue", error.message)
    end
  end

  defp update_user(ctx, user, attrs) do
    email = attrs.email && Email.normalize(attrs.email)

    if email != user.email and Store.get_by(ctx, :user, email: email),
      do: {:scim_error, 409, "uniqueness", "Another user has this email"},
      else: Store.update(ctx, :user, user, %{email: email, name: attrs.name})
  end

  @doc "A user's SCIM id lookup, within the connection."
  def find(%Context{raw_params: %{"id" => id}} = ctx) do
    connection = ctx.private.scim_connection

    with %{deprovisioned_at: nil} = link <-
           Store.get_by(ctx, :scim_user, id: id, scim_connection_id: connection.id),
         %{} = user <- Store.get_by(ctx, :user, id: link.user_id) do
      {link, user}
    else
      _missing -> nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  # The request body as attrs: userName, emails, name, active, externalId.
  @doc false
  def parse(params) do
    user_name = params["userName"]
    email = email(params, user_name)
    name = params["name"] || %{}

    cond do
      not is_binary(user_name) or user_name == "" ->
        {:scim_error, 400, "invalidValue", "userName is required"}

      is_nil(email) ->
        {:scim_error, 400, "invalidValue", "An email is required, in emails or userName"}

      true ->
        {:ok,
         %{
           user_name: user_name,
           email: email,
           given_name: name["givenName"],
           family_name: name["familyName"],
           name: display_name(params, name, user_name),
           external_id: params["externalId"],
           active: Patch.boolean(Map.get(params, "active", true))
         }}
    end
  end

  # The primary email, or the userName when it's an address.
  defp email(params, user_name) do
    email =
      primary_email(params["emails"]) ||
        if(is_binary(user_name) and String.contains?(user_name, "@"), do: user_name)

    if is_binary(email) and Email.valid?(Email.normalize(email)), do: email
  end

  defp primary_email(emails) when is_list(emails) do
    emails = Enum.filter(emails, &(is_map(&1) and is_binary(&1["value"])))
    email = Enum.find(emails, &Patch.boolean(&1["primary"])) || List.first(emails)
    email && email["value"]
  end

  defp primary_email(_emails), do: nil

  defp display_name(params, name, user_name) do
    full = [name["givenName"], name["familyName"]] |> Enum.filter(&is_binary/1) |> Enum.join(" ")
    params["displayName"] || name["formatted"] || (full != "" && full) || user_name
  end

  defp current(link, user) do
    %{
      user_name: link.user_name,
      email: user.email,
      given_name: link.given_name,
      family_name: link.family_name,
      name: user.name,
      external_id: link.external_id,
      active: link.active
    }
  end

  defp unique_user_name(ctx, connection, user_name, except_id) do
    query =
      from(l in Store.module(ctx, :scim_user),
        where:
          l.scim_connection_id == ^connection.id and is_nil(l.deprovisioned_at) and
            fragment("lower(?)", l.user_name) == ^String.downcase(user_name)
      )

    query = if except_id, do: where(query, [l], l.id != ^except_id), else: query

    if Store.count(ctx, :scim_user, query) == 0,
      do: :ok,
      else: {:scim_error, 409, "uniqueness", "userName is taken"}
  end

  # The app's choice, then an existing user (when allowed), then a new one.
  defp user_for(ctx, connection, attrs) do
    opts = Config.opts(ctx)
    email = Email.normalize(attrs.email)

    choice =
      case opts[:resolve_user] do
        nil -> :default
        resolve -> resolve.(attrs, connection, ctx)
      end

    existing = Store.get_by(ctx, :user, email: email)

    cond do
      match?({:ok, %{}}, choice) ->
        choice

      match?({:error, _}, choice) ->
        {:scim_error, 409, "uniqueness", "The user can't be provisioned"}

      is_nil(existing) ->
        Store.insert(ctx, :user, %{email: email, name: attrs.name, email_verified: false})

      opts[:link_existing_users] ->
        {:ok, existing}

      true ->
        {:scim_error, 409, "uniqueness", "A user with this email exists"}
    end
  end

  defp insert_link(ctx, connection, user, attrs) do
    Store.insert(
      ctx,
      :scim_user,
      Map.merge(link_attrs(attrs), %{scim_connection_id: connection.id, user_id: user.id})
    )
  end

  defp link_attrs(attrs) do
    Map.take(attrs, [:user_name, :external_id, :given_name, :family_name, :active])
  end

  defp join_organization(%Context{config: config} = ctx, %{organization_id: org_id}, user)
       when is_binary(org_id) do
    if Organization in Enum.map(config.plugins, &elem(&1, 0)) do
      case Organization.add_member(config.auth, org_id, user.id, Config.opts(ctx)[:default_role]) do
        {:ok, _member} -> :ok
        {:error, %Error{code: :already_member}} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp join_organization(_ctx, _connection, _user), do: :ok

  @doc "A user as SCIM JSON."
  def render(ctx, {link, user}) do
    %{
      schemas: [@user_schema],
      id: to_string(link.id),
      externalId: link.external_id,
      userName: link.user_name,
      displayName: user.name,
      name:
        %{givenName: link.given_name, familyName: link.family_name, formatted: user.name}
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
      emails: [%{value: user.email, type: "work", primary: true}],
      active: link.active,
      meta: Lists.meta(ctx, "User", "/scim/v2/Users/", link)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
