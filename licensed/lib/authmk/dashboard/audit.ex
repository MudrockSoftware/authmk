defmodule Authmk.Dashboard.Audit do
  @moduledoc false
  # Every change made from the dashboard goes to the audit log
  # (Authmk.Plugins.AuditLog) as a `dashboard.*` event, with the admin as
  # the actor, besides the events the change itself records (like
  # `user.updated`). Without the audit log plugin there's nowhere to write
  # them: the health checks warn about it.

  alias Authmk.Dashboard.Data
  alias Authmk.Plugins.AuditLog

  @doc """
  Records `name` (like `"dashboard.user.banned"`) by `admin`. `details`:
  `:user_id`, `:organization_id` and `:metadata` (ids, roles, plans: never
  secrets).
  """
  def record(ctx, admin, name, details) do
    if Data.enabled?(ctx, AuditLog),
      do: AuditLog.record(ctx, "dashboard." <> name, Map.put(details, :actor, admin))

    :ok
  end
end
