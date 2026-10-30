defmodule Authmk.Plugins.Admin do
  @moduledoc """
  User administration: create, list, update and remove users, set roles and
  passwords, ban users, manage their sessions and impersonate them.

      use Authmk,
        plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.Admin, admin_user_ids: ["..."]}],
        ...

  Users get a `role` (comma-separated role names; `default_role` for new
  users) and ban fields. Every endpoint needs a signed-in user allowed to do
  that action: by role, through `access_control` (see
  `Authmk.Plugins.Admin.Permissions`), or by being in `admin_user_ids`.

  | Method | Path | Permission |
  |---|---|---|
  | POST | `/admin/create-user` | `user: create` |
  | GET | `/admin/list-users` | `user: list` |
  | GET | `/admin/get-user` | `user: get` |
  | POST | `/admin/update-user` | `user: update` |
  | POST | `/admin/set-role` | `user: set_role` |
  | POST | `/admin/set-user-password` | `user: set_password` |
  | POST | `/admin/ban-user` | `user: ban` |
  | POST | `/admin/unban-user` | `user: ban` |
  | POST | `/admin/list-user-sessions` | `session: list` |
  | POST | `/admin/revoke-user-session` | `session: revoke` |
  | POST | `/admin/revoke-user-sessions` | `session: revoke` |
  | POST | `/admin/remove-user` | `user: delete` |
  | POST | `/admin/impersonate-user` | `user: impersonate` (`impersonate_admins` for admins) |
  | POST | `/admin/stop-impersonating` | (the impersonation session) |
  | POST | `/admin/has-permission` | (any signed-in user) |

  `GET /admin/list-users` takes `search_value`, `search_field` (`email` or
  `name`), `search_operator` (`contains`, `starts_with`, `ends_with`),
  `filter_field`, `filter_value`, `filter_operator` (`eq`, `ne`, `lt`, `lte`,
  `gt`, `gte`, `contains`), `sort_by`, `sort_direction`, `limit` (at most 100)
  and `offset`, and answers with `users` and their `total`.

  Banning a user signs them out everywhere, and no sign-in method creates a
  session for them until the ban ends (`ban_expires_in` seconds, or never).

  Impersonating signs the admin in as the user for
  `impersonation_session_duration` seconds; the session has
  `impersonated_by_id`. `POST /admin/stop-impersonating` ends it and brings the
  admin's own session back.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Admin.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    AccessControl,
    Context,
    Cookies,
    Credentials,
    Crypto,
    Email,
    Endpoint,
    Error,
    PasswordPolicy,
    Serializer,
    Sessions,
    SessionStore,
    Store,
    Token
  }

  alias Authmk.Plugins.Admin.{Options, UserQuery}

  @admin_cookie_purpose "admin-session"

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema())
    access_control = opts[:access_control]

    unless Code.ensure_loaded?(access_control) and
             function_exported?(access_control, :access_control, 0) do
      raise ArgumentError, "#{inspect(access_control)} must `use Authmk.AccessControl`"
    end

    opts
  end

  @impl true
  def schema(opts) do
    %{
      user: [
        fields: [
          role: [type: :string, default: opts[:default_role] || "user", input: false],
          banned: [type: :boolean, default: false, input: false],
          ban_reason: [type: :string, input: false],
          ban_expires: [type: :datetime, input: false]
        ]
      ],
      session: [
        fields: [impersonated_by_id: [references: :user, on_delete: :delete_all, input: false]]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    user_id = [user_id: [type: :string, required: true]]

    [
      endpoint(:admin_create_user, :post, "/admin/create-user", :create_user,
        params: [
          email: [type: :string, required: true],
          name: [type: :string, required: true],
          password: [type: :string],
          role: [type: :string],
          data: [type: :map]
        ]
      ),
      endpoint(:admin_list_users, :get, "/admin/list-users", :list_users,
        params: [
          search_value: [type: :string],
          search_field: [type: :string],
          search_operator: [type: :string],
          filter_field: [type: :string],
          filter_value: [type: :string],
          filter_operator: [type: :string],
          sort_by: [type: :string],
          sort_direction: [type: :string],
          limit: [type: :integer],
          offset: [type: :integer]
        ]
      ),
      endpoint(:admin_get_user, :get, "/admin/get-user", :get_user,
        params: [id: [type: :string, required: true]]
      ),
      endpoint(:admin_update_user, :post, "/admin/update-user", :update_user,
        params: user_id ++ [data: [type: :map, required: true]]
      ),
      endpoint(:admin_set_role, :post, "/admin/set-role", :set_role,
        params: user_id ++ [role: [type: :string, required: true]]
      ),
      endpoint(:admin_set_user_password, :post, "/admin/set-user-password", :set_password,
        params: user_id ++ [new_password: [type: :string, required: true]]
      ),
      endpoint(:admin_ban_user, :post, "/admin/ban-user", :ban,
        params: user_id ++ [ban_reason: [type: :string], ban_expires_in: [type: :integer]]
      ),
      endpoint(:admin_unban_user, :post, "/admin/unban-user", :unban, params: user_id),
      endpoint(:admin_list_user_sessions, :post, "/admin/list-user-sessions", :list_sessions,
        params: user_id
      ),
      endpoint(:admin_revoke_user_session, :post, "/admin/revoke-user-session", :revoke_session,
        params: user_id ++ [session_id: [type: :string, required: true]]
      ),
      endpoint(
        :admin_revoke_user_sessions,
        :post,
        "/admin/revoke-user-sessions",
        :revoke_sessions,
        params: user_id
      ),
      endpoint(:admin_remove_user, :post, "/admin/remove-user", :remove_user, params: user_id),
      endpoint(:admin_impersonate_user, :post, "/admin/impersonate-user", :impersonate,
        params: user_id
      ),
      endpoint(
        :admin_stop_impersonating,
        :post,
        "/admin/stop-impersonating",
        :stop_impersonating
      ),
      endpoint(:admin_has_permission, :post, "/admin/has-permission", :has_permission,
        params: [permissions: [type: :map, required: true], role: [type: :string]]
      )
    ]
  end

  # Every session creation passes here: banned users get none, whatever the
  # sign-in method. Impersonation sessions are the admin's, not the user's.
  @impl true
  def database_hook(:before_create, :session, attrs, ctx) do
    if attrs[:impersonated_by_id],
      do: {:ok, attrs},
      else: check_ban(ctx, Store.get_by(ctx, :user, id: attrs[:user_id]), attrs)
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @doc false
  def create_user(%Context{params: params} = ctx) do
    opts = opts(ctx)
    email = Email.normalize(params.email)
    role = params.role || opts[:default_role]

    with :ok <- authorize(ctx, user: [:create]),
         :ok <- check(Email.valid?(email), Error.new(:invalid_email)),
         :ok <- valid_role(ctx, role),
         :ok <-
           check(is_nil(Store.get_by(ctx, :user, email: email)), Error.new(:user_already_exists)),
         :ok <- valid_password(params.password),
         attrs =
           Map.merge(data(params.data), %{"email" => email, "name" => params.name, "role" => role}),
         {:ok, user} <- create_with_password(ctx, attrs, params.password) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def list_users(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:list]),
         {:ok, query, limit, offset} <- user_query(ctx, params) do
      users = Store.list(ctx, :user, query)

      {:ok,
       %{
         users: Enum.map(users, &Serializer.user(ctx, &1)),
         total: Store.count(ctx, :user, query),
         limit: limit,
         offset: offset
       }, ctx}
    end
  end

  @doc false
  def get_user(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:get]),
         {:ok, user} <- fetch_user(ctx, params.id) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def update_user(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:update]),
         {:ok, data} <- updatable(params.data),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         {:ok, user} <- Store.update(ctx, :user, user, data) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def set_role(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:set_role]),
         :ok <- valid_role(ctx, params.role),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         {:ok, user} <- Store.update(ctx, :user, user, %{role: params.role}) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def set_password(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:set_password]),
         :ok <- valid_password(params.new_password),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         {:ok, _account} <- Credentials.set_password(ctx, user, params.new_password) do
      {:ok, %{status: true}, ctx}
    end
  end

  @doc false
  def ban(%Context{params: params, user: admin} = ctx) do
    opts = opts(ctx)
    expires_in = params.ban_expires_in || opts[:default_ban_expires_in]

    attrs = %{
      banned: true,
      ban_reason: params.ban_reason || opts[:default_ban_reason],
      ban_expires: if(expires_in, do: DateTime.add(DateTime.utc_now(), expires_in))
    }

    with :ok <- authorize(ctx, user: [:ban]),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         :ok <-
           check(
             user.id != admin.id,
             Error.custom(:cannot_ban_yourself, 400, "You can't ban yourself")
           ),
         {:ok, user} <- Store.update(ctx, :user, user, attrs) do
      :ok = Sessions.revoke_all(ctx, user.id)
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def unban(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, user: [:ban]),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         {:ok, user} <- Store.update(ctx, :user, user, unbanned()) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  @doc false
  def list_sessions(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, session: [:list]),
         {:ok, user} <- fetch_user(ctx, params.user_id) do
      {:ok, %{sessions: Enum.map(Sessions.list(ctx, user.id), &Serializer.session(ctx, &1))}, ctx}
    end
  end

  @doc false
  def revoke_session(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, session: [:revoke]),
         {:ok, user} <- fetch_user(ctx, params.user_id) do
      :ok = Sessions.revoke(ctx, user.id, params.session_id)
      {:ok, %{status: true}, ctx}
    end
  end

  @doc false
  def revoke_sessions(%Context{params: params} = ctx) do
    with :ok <- authorize(ctx, session: [:revoke]),
         {:ok, user} <- fetch_user(ctx, params.user_id) do
      :ok = Sessions.revoke_all(ctx, user.id)
      {:ok, %{status: true}, ctx}
    end
  end

  @doc false
  def remove_user(%Context{params: params, user: admin} = ctx) do
    with :ok <- authorize(ctx, user: [:delete]),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         :ok <-
           check(
             user.id != admin.id,
             Error.custom(:cannot_remove_yourself, 400, "You can't remove yourself")
           ),
         :ok <- Sessions.revoke_all(ctx, user.id),
         {:ok, _user} <- Store.delete(ctx, :user, user) do
      {:ok, %{status: true}, ctx}
    end
  end

  @doc false
  # The admin's session token waits in a signed cookie until they stop.
  def impersonate(%Context{params: params, user: admin, config: config} = ctx) do
    opts = opts(ctx)

    with :ok <- authorize(ctx, user: [:impersonate]),
         {:ok, user} <- fetch_user(ctx, params.user_id),
         :ok <- may_impersonate(ctx, user, opts),
         {:ok, admin_token} <- Cookies.session_token(ctx) |> session_token(),
         expires_at = DateTime.add(DateTime.utc_now(), opts[:impersonation_session_duration]),
         {:ok, ctx} <-
           Sessions.create(ctx, user, false, %{
             impersonated_by_id: admin.id,
             expires_at: expires_at
           }) do
      admin_cookie = Crypto.sign(config, @admin_cookie_purpose, admin_token)
      ctx = Cookies.put(ctx, :admin_session, admin_cookie, opts[:impersonation_session_duration])

      {:ok, %{session: Serializer.session(ctx, ctx.session), user: Serializer.user(ctx, user)},
       ctx}
    end
  end

  @doc false
  def stop_impersonating(%Context{session: session, config: config} = ctx) do
    with :ok <-
           check(
             not is_nil(session.impersonated_by_id),
             Error.custom(:not_impersonating, 400, "You aren't impersonating anyone")
           ),
         signed when is_binary(signed) <- Cookies.get(ctx, :admin_session),
         {:ok, token} <- Crypto.verify(config, @admin_cookie_purpose, signed),
         %{} = admin_session <- SessionStore.fetch(ctx, Token.hash(token)),
         true <- admin_session.user_id == session.impersonated_by_id,
         true <- DateTime.after?(admin_session.expires_at, DateTime.utc_now()),
         :ok <- SessionStore.delete(ctx, session) do
      ctx = ctx |> Cookies.delete(:admin_session) |> Cookies.put_session(token, true)

      {:ok, %{user: Serializer.user(ctx, admin_session.user)},
       %{ctx | session: admin_session, user: admin_session.user}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _no_admin_session ->
        {:error, Error.custom(:admin_session_not_found, 400, "Sign in again as yourself")}
    end
  end

  @doc false
  def has_permission(%Context{params: params, user: user} = ctx) do
    access_control = opts(ctx)[:access_control]
    role = params.role || user.role
    {:ok, %{success: access_control.has_permission?(role, params.permissions)}, ctx}
  end

  @doc """
  Whether `user` may do `permissions` (`%{user: [:ban]}`): by being in
  `admin_user_ids`, or by role. For your own server-side checks.
  """
  @spec allowed?(Context.t(), struct(), AccessControl.permissions()) :: boolean()
  def allowed?(ctx, user, permissions) do
    opts = opts(ctx)

    to_string(user.id) in opts[:admin_user_ids] or
      opts[:access_control].has_permission?(user.role, permissions)
  end

  defp authorize(%Context{user: user} = ctx, permissions) do
    check(allowed?(ctx, user, permissions), Error.new(:forbidden))
  end

  # Admins can only be impersonated with `impersonate_admins`.
  defp may_impersonate(ctx, target, opts) do
    target_is_admin =
      to_string(target.id) in opts[:admin_user_ids] or
        Enum.any?(AccessControl.parse_roles(target.role), &(&1 in opts[:admin_roles]))

    if target_is_admin and target.id != ctx.user.id,
      do: authorize(ctx, user: [:impersonate_admins]),
      else: :ok
  end

  defp check_ban(_ctx, nil, attrs), do: {:ok, attrs}
  defp check_ban(_ctx, %{banned: false}, attrs), do: {:ok, attrs}

  defp check_ban(ctx, user, attrs) do
    if user.ban_expires && DateTime.before?(user.ban_expires, DateTime.utc_now()) do
      # The ban is over.
      with {:ok, _user} <- Store.update(ctx, :user, user, unbanned()), do: {:ok, attrs}
    else
      {:error, Error.custom(:banned, 403, opts(ctx)[:banned_user_message])}
    end
  end

  defp unbanned, do: %{banned: false, ban_reason: nil, ban_expires: nil}

  defp create_with_password(ctx, attrs, nil), do: Store.insert(ctx, :user, attrs)

  defp create_with_password(ctx, attrs, password) do
    Store.transaction(ctx, fn ->
      with {:ok, user} <- Store.insert(ctx, :user, attrs),
           {:ok, _account} <- Credentials.set_password(ctx, user, password) do
        {:ok, user}
      end
    end)
  end

  # Extra user fields an admin may set. Roles and bans have their own endpoints.
  defp data(nil), do: %{}
  defp data(data), do: Map.drop(data, ["id", "role", "banned", "ban_reason", "ban_expires"])

  # The id is the user's identity; roles and bans have their own endpoints,
  # with their own permissions. Asking to change them here is an error, not
  # something to drop quietly.
  defp updatable(data) do
    data = data || %{}

    cond do
      Map.has_key?(data, "id") ->
        {:error, Error.custom(:user_id_cannot_be_updated, 400, "A user's id can't be changed")}

      key = Enum.find(["role", "banned", "ban_reason", "ban_expires"], &Map.has_key?(data, &1)) ->
        {:error,
         Error.custom(:field_not_updatable, 400, "Change #{key} with set-role, ban or unban")}

      true ->
        {:ok, data}
    end
  end

  defp user_query(ctx, params) do
    case UserQuery.build(Store.module(ctx, :user), params) do
      {:ok, query, limit, offset} -> {:ok, query, limit, offset}
      {:error, _reason} -> {:error, Error.new(:bad_request)}
    end
  end

  defp fetch_user(ctx, id) do
    case Store.get_by(ctx, :user, id: id) do
      nil -> {:error, Error.custom(:user_not_found, 404, "User not found")}
      user -> {:ok, user}
    end
  rescue
    Ecto.Query.CastError -> {:error, Error.custom(:user_not_found, 404, "User not found")}
  end

  defp valid_role(ctx, role) do
    access_control = opts(ctx)[:access_control].access_control()

    check(
      AccessControl.valid_roles?(access_control, role),
      Error.custom(:invalid_role, 422, "Unknown role")
    )
  end

  defp valid_password(nil), do: :ok
  defp valid_password(password), do: PasswordPolicy.check_length(password, 8, 128)

  defp session_token({:ok, token}), do: {:ok, token}
  defp session_token(_none), do: {:error, Error.new(:unauthorized)}

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  defp check(true, _error), do: :ok
  defp check(_false, error), do: {:error, error}

  defp endpoint(name, method, path, function, opts \\ []) do
    Endpoint.new(
      [
        name: name,
        method: method,
        path: path,
        handler: {__MODULE__, function},
        session: :required
      ] ++ opts
    )
  end
end
