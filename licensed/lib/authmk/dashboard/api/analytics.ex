defmodule Authmk.Dashboard.API.Analytics do
  @moduledoc false
  # Analytics for a date range and organization, and CSV exports of users,
  # audit events and the daily analytics. Exports hold personal data: they
  # need the Admin permission `user: list`, are capped at 50,000 rows, and
  # each one is written to the audit log.

  import Ecto.Query
  import Plug.Conn

  alias Authmk.Dashboard.{Access, Audit, CSV, Data, Reply}
  alias Authmk.Dashboard.Data.{Analytics, Fields, Users}
  alias Authmk.Plugins.AuditLog
  alias Authmk.Store

  @max_rows 50_000
  @exports ["users.csv", "events.csv", "analytics.csv"]

  def route(%Plug.Conn{method: "GET"} = conn, [], ctx, _admin) do
    case range(conn) do
      {:ok, first, last} ->
        report = Analytics.report(ctx, first, last, Reply.param(conn, "organization_id"))
        Reply.json(conn, 200, report)

      {:error, message} ->
        Reply.error(conn, 400, "invalid_range", message)
    end
  end

  def route(conn, _path, _ctx, _admin), do: Reply.not_found(conn)

  def export(%Plug.Conn{method: "GET"} = conn, [name], ctx, admin) when name in @exports do
    kind = String.trim_trailing(name, ".csv")

    if Access.can?(ctx, admin, %{user: [:list]}) do
      case table(kind, conn, ctx) do
        {:ok, header, rows} ->
          :ok = Audit.record(ctx, admin, "export." <> kind, %{metadata: %{rows: length(rows)}})
          send_csv(conn, name, header, rows)

        {:error, message} ->
          Reply.error(conn, 400, "invalid_request", message)
      end
    else
      Reply.forbidden(conn)
    end
  end

  def export(conn, _path, _ctx, _admin), do: Reply.not_found(conn)

  defp table("users", conn, ctx) do
    filters = [
      search: Reply.param(conn, "search"),
      status: Reply.param(conn, "status"),
      organization_id: Reply.param(conn, "organization_id")
    ]

    fields = Enum.map(Fields.definitions(ctx, :user), & &1.name)

    users =
      from(u in Store.module(ctx, :user), order_by: [desc: u.inserted_at], limit: @max_rows)
      |> Users.filter(ctx, filters)
      |> then(&Store.list(ctx, :user, &1))

    header =
      ~w(id email name email_verified role banned two_factor_enabled created_at) ++ fields

    rows =
      for user <- users do
        values = Fields.values(ctx, :user, user)
        shown = Data.user(user)

        [
          shown.id,
          shown.email,
          shown.name,
          shown.email_verified,
          shown.role,
          shown.banned,
          shown.two_factor_enabled,
          shown.created_at
        ] ++ Enum.map(fields, &values[&1])
      end

    {:ok, header, rows}
  end

  defp table("events", conn, ctx) do
    with true <- Data.enabled?(ctx, AuditLog) || {:error, "The audit log isn't on."},
         {:ok, first, last} <- range(conn) do
      events =
        ctx
        |> events_query(conn, first, last)
        |> then(&Store.list(ctx, :audit_event, &1))

      header =
        ~w(id event user_id actor_type actor_id organization_id ip_address created_at metadata)

      rows =
        for event <- events,
            do: [
              event.id,
              event.event,
              event.user_id,
              event.actor_type,
              event.actor_id,
              event.organization_id,
              event.ip_address,
              event.inserted_at,
              event.metadata
            ]

      {:ok, header, rows}
    end
  end

  defp table("analytics", conn, ctx) do
    with {:ok, first, last} <- range(conn) do
      report = Analytics.report(ctx, first, last, Reply.param(conn, "organization_id"))
      header = ~w(day sign_ups sign_ins active_users failed_sign_ins)
      {:ok, header, Analytics.daily_rows(report)}
    end
  end

  defp events_query(ctx, conn, first, last) do
    from_time = DateTime.new!(first, ~T[00:00:00])
    until = DateTime.new!(Date.add(last, 1), ~T[00:00:00])

    query =
      from(e in Store.module(ctx, :audit_event),
        where: e.inserted_at >= ^from_time and e.inserted_at < ^until,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: @max_rows
      )

    Enum.reduce([:event, :user_id, :organization_id], query, fn field, query ->
      case Reply.param(conn, Atom.to_string(field)) do
        nil -> query
        value -> where(query, [e], field(e, ^field) == ^value)
      end
    end)
  end

  defp send_csv(conn, name, header, rows) do
    filename = "#{String.trim_trailing(name, ".csv")}-#{Date.to_iso8601(Date.utc_today())}.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, CSV.encode(header, rows))
  end

  defp range(conn), do: Analytics.range(Reply.param(conn, "from"), Reply.param(conn, "to"))
end
