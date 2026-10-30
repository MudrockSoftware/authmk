defmodule Authmk.Plug.RequireRole do
  @moduledoc """
  Lets through only signed-in users with a role, or with permissions. Use
  after `Authmk.Plug.FetchSession`.

      # Any of these roles (the user's `role`, comma-separated, from
      # Authmk.Plugins.Admin).
      plug Authmk.Plug.RequireRole, roles: ["admin", "support"]

      # Permissions, by Authmk.Plugins.Admin's access control (users in
      # its `admin_user_ids` too).
      plug Authmk.Plug.RequireRole, auth: MyApp.Auth, permissions: %{user: [:ban]}

  Signed-out requests get 401 and others 403, as JSON, or a redirect with
  `redirect_to:`. Service accounts have no role: they're refused.
  """

  @behaviour Plug

  alias Authmk.{AccessControl, Context, Error}
  alias Authmk.Plug.Refusal
  alias Authmk.Plugins.Admin

  @impl true
  def init(opts) do
    roles = opts[:roles]
    permissions = opts[:permissions]

    cond do
      roles && permissions ->
        raise ArgumentError, "RequireRole takes roles: or permissions:, not both"

      roles ->
        %{check: {:roles, AccessControl.parse_roles(roles)}, redirect_to: opts[:redirect_to]}

      permissions ->
        auth = Keyword.fetch!(opts, :auth)
        %{check: {:permissions, auth, permissions}, redirect_to: opts[:redirect_to]}

      true ->
        raise ArgumentError, "RequireRole needs roles: or permissions:"
    end
  end

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, opts) when not is_nil(user) do
    if allowed?(opts.check, user),
      do: conn,
      else: Refusal.refuse(conn, Error.new(:forbidden), opts.redirect_to)
  end

  def call(conn, opts), do: Refusal.refuse(conn, Error.new(:unauthorized), opts.redirect_to)

  defp allowed?({:roles, roles}, user),
    do: Enum.any?(AccessControl.parse_roles(Map.get(user, :role)), &(&1 in roles))

  defp allowed?({:permissions, auth, permissions}, user) do
    config = auth.config()

    if Admin not in Enum.map(config.plugins, &elem(&1, 0)),
      do:
        raise(
          ArgumentError,
          "RequireRole's permissions: need Authmk.Plugins.Admin in #{inspect(auth)}"
        )

    Admin.allowed?(Context.new(config), user, permissions)
  end
end
