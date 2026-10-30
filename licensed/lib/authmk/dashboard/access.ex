defmodule Authmk.Dashboard.Access do
  @moduledoc false
  # Who may use the dashboard: a signed-in admin (by `can_access`, or
  # Authmk.Plugins.Admin's rules), checked on every request from the
  # session cookie, so a sign-out or a lost role ends access at once. Each
  # action also checks its own Admin permission.

  alias Authmk.{BaseURL, Context, Sessions}
  alias Authmk.Plugins.Admin

  @doc "`{:ok, ctx, user}`, `:signed_out` or `:forbidden`."
  def admin(conn, %{auth: auth} = opts) do
    config = auth.config()

    with {:ok, base_url} <- BaseURL.resolve(config, conn),
         ctx =
           Sessions.load(%Context{
             config: config,
             conn: Plug.Conn.fetch_cookies(conn),
             base_url: base_url
           }),
         %{} = user <- ctx.user do
      if allowed?(opts, ctx, user), do: {:ok, ctx, user}, else: :forbidden
    else
      _signed_out -> :signed_out
    end
  end

  defp allowed?(%{can_access: {module, function}, auth: auth}, _ctx, user),
    do: apply(module, function, [user, auth]) == true

  defp allowed?(_opts, ctx, user), do: can?(ctx, user, %{user: [:list]})

  @doc "Whether the admin may do `permissions` (Admin's rules; without the Admin plugin, no actions)."
  def can?(%Context{config: config} = ctx, user, permissions) do
    Admin in Enum.map(config.plugins, &elem(&1, 0)) and Admin.allowed?(ctx, user, permissions)
  end
end
