defmodule Authmk.Dashboard.Data.Analytics do
  @moduledoc false
  # Sign-in analytics for a date range (at most a year), optionally for one
  # organization's members: active users, sign-ins and sign-ups per day and
  # by method, failed sign-ins, and how many users verified their email and
  # set up a second factor.
  #
  # Sign-ins, methods and failures come from the audit log
  # (Authmk.Plugins.AuditLog), which keeps them after sessions end. Without
  # it, sign-ins are counted from the sessions still stored, and methods and
  # failures aren't known. Days are UTC. Each series is one query grouped
  # by day, written for each database (SQLite stores times as text).

  import Ecto.Query

  alias Authmk.Dashboard.Data
  alias Authmk.{Migration, Store}
  alias Authmk.Plugins.AuditLog

  @max_days 366
  # Methods are read from events' JSON metadata, in Elixir: at most this many.
  @method_sample 50_000
  # An organization's members, for filtering events by their user id.
  @max_members 10_000

  @doc """
  The range from `from` and `to` (ISO 8601 dates, both included): the last
  30 days by default. `{:ok, first, last}` or `{:error, message}`.
  """
  def range(from, to) do
    today = Date.utc_today()

    with {:ok, last} <- date(to, today),
         {:ok, first} <- date(from, Date.add(last, -29)) do
      cond do
        Date.after?(first, last) -> {:error, "The range starts after it ends."}
        Date.diff(last, first) >= @max_days -> {:error, "The range can be a year at most."}
        true -> {:ok, first, last}
      end
    end
  end

  defp date(nil, default), do: {:ok, default}

  defp date(text, _default) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _invalid} -> {:error, "Dates look like 2026-10-30."}
    end
  end

  ## The overview's charts: the last `days` days, everyone

  def sign_ups_per_day(ctx, days), do: report_series(ctx, last_days(days), &sign_ups/3)
  def sign_ins_per_day(ctx, days), do: report_series(ctx, last_days(days), &sign_ins/3)

  defp last_days(days) do
    today = Date.utc_today()
    {Date.add(today, -(days - 1)), today}
  end

  defp report_series(ctx, {first, last}, series), do: series.(ctx, scope(first, last, nil), nil)

  ## The analytics page

  def report(ctx, first, last, organization_id) do
    scope = scope(first, last, organization_id)
    members = member_ids(ctx, organization_id)
    audit_log = Data.enabled?(ctx, AuditLog)

    %{
      from: first,
      to: last,
      organization_id: organization_id,
      source: if(audit_log, do: "audit_log", else: "sessions"),
      active_users: active_users(ctx, scope, members),
      sign_ins: sign_ins(ctx, scope, members),
      sign_ups: sign_ups(ctx, scope, organization_id),
      # Failed sign-ins aren't anyone's yet: not per organization.
      failed_sign_ins: if(audit_log and is_nil(organization_id), do: failed(ctx, scope)),
      sign_ins_by_method: if(audit_log, do: methods(ctx, scope, "session.created", members)),
      sign_ups_by_method: if(audit_log, do: methods(ctx, scope, "user.created", members)),
      failure_reasons: if(audit_log and is_nil(organization_id), do: failure_reasons(ctx, scope)),
      adoption: adoption(ctx, organization_id)
    }
  end

  defp scope(first, last, organization_id) do
    %{
      first: first,
      last: last,
      from: DateTime.new!(first, ~T[00:00:00]),
      until: DateTime.new!(Date.add(last, 1), ~T[00:00:00]),
      organization_id: organization_id
    }
  end

  defp sign_ups(ctx, scope, organization_id) do
    from(u in Store.module(ctx, :user))
    |> Data.in_organization(ctx, organization_id)
    |> per_day(ctx, :user, scope, :count)
  end

  defp sign_ins(ctx, scope, members) do
    if Data.enabled?(ctx, AuditLog),
      do: ctx |> events("session.created", members) |> per_day(ctx, :audit_event, scope, :count),
      else: ctx |> sessions(scope.organization_id) |> per_day(ctx, :session, scope, :count)
  end

  defp active_users(ctx, scope, members) do
    if Data.enabled?(ctx, AuditLog),
      do: ctx |> events("session.created", members) |> per_day(ctx, :audit_event, scope, :users),
      else: ctx |> sessions(scope.organization_id) |> per_day(ctx, :session, scope, :users)
  end

  defp failed(ctx, scope),
    do: ctx |> events("sign_in.failed", nil) |> per_day(ctx, :audit_event, scope, :count)

  defp events(ctx, name, members) do
    query = from(e in Store.module(ctx, :audit_event), where: e.event == ^name)
    if members, do: where(query, [e], e.user_id in ^members), else: query
  end

  defp sessions(ctx, nil), do: from(s in Store.module(ctx, :session))

  defp sessions(ctx, organization_id) do
    case Data.safe_get(ctx, :organization, organization_id) do
      nil ->
        from(s in Store.module(ctx, :session), where: false)

      organization ->
        members =
          from(m in Store.module(ctx, :member),
            where: m.organization_id == ^organization.id,
            select: m.user_id
          )

        from(s in Store.module(ctx, :session), where: s.user_id in subquery(members))
    end
  end

  # The ids (as text) of an organization's members, or `nil` for everyone.
  defp member_ids(_ctx, nil), do: nil

  defp member_ids(ctx, organization_id) do
    case Data.safe_get(ctx, :organization, organization_id) do
      nil ->
        []

      organization ->
        from(m in Store.module(ctx, :member),
          where: m.organization_id == ^organization.id,
          select: m.user_id,
          limit: @max_members
        )
        |> then(&Store.list(ctx, :member, &1))
        |> Enum.map(&to_string/1)
    end
  end

  @doc "How many `model` rows have `field` (a time) on each day of the range."
  def per_day_of(ctx, model, field, first, last) do
    from(r in Store.module(ctx, model))
    |> per_day(ctx, model, scope(first, last, nil), :count, field)
  end

  # One count per day (`:count` rows, or `:users`, distinct users) of the
  # time in `field`, every day of the range listed, oldest first.
  defp per_day(query, ctx, model, scope, measure, field \\ :inserted_at) do
    day = day_of(ctx, field)

    counts =
      query
      |> where([r], field(r, ^field) >= ^scope.from and field(r, ^field) < ^scope.until)
      |> group_by(^[day])
      |> select(^%{day: day, count: measure(measure)})
      |> then(&Store.list(ctx, model, &1))
      |> Map.new(&{to_date(&1.day), &1.count})

    for day <- Date.range(scope.first, scope.last),
        do: %{day: Date.to_iso8601(day), count: Map.get(counts, day, 0)}
  end

  defp measure(:count), do: dynamic([r], count(r.id))
  defp measure(:users), do: dynamic([r], count(r.user_id, :distinct))

  defp day_of(ctx, field) do
    case Migration.adapter(ctx.config.repo) do
      :sqlite -> dynamic([r], fragment("substr(?, 1, 10)", field(r, ^field)))
      _server -> dynamic([r], fragment("CAST(? AS DATE)", field(r, ^field)))
    end
  end

  defp to_date(%Date{} = date), do: date
  defp to_date(text) when is_binary(text), do: Date.from_iso8601!(text)

  # How many events of `name` each method has, most first.
  defp methods(ctx, scope, name, members) do
    ctx
    |> events(name, members)
    |> metadata_in(ctx, scope)
    |> Enum.frequencies_by(&(&1["method"] || "other"))
    |> ranked(:method)
  end

  defp failure_reasons(ctx, scope) do
    ctx
    |> events("sign_in.failed", nil)
    |> metadata_in(ctx, scope)
    |> Enum.frequencies_by(&(&1["code"] || "unknown"))
    |> ranked(:code)
  end

  defp metadata_in(query, ctx, scope) do
    query
    |> where([e], e.inserted_at >= ^scope.from and e.inserted_at < ^scope.until)
    |> order_by([e], desc: e.inserted_at)
    |> limit(@method_sample)
    |> select([e], e.metadata)
    |> then(&Store.list(ctx, :audit_event, &1))
    |> Enum.map(&decode/1)
  end

  defp decode(nil), do: %{}

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, %{} = metadata} -> metadata
      _other -> %{}
    end
  end

  defp ranked(frequencies, key) do
    frequencies
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> Enum.map(fn {name, count} -> %{key => name, :count => count} end)
  end

  # How many users verified their email and set up each second factor, now.
  defp adoption(ctx, organization_id) do
    users = Data.in_organization(from(u in Store.module(ctx, :user)), ctx, organization_id)

    %{
      users: Store.count(ctx, :user, users),
      verified_email: Store.count(ctx, :user, where(users, [u], u.email_verified == true)),
      two_factor:
        if(Data.field?(ctx, :user, :two_factor_enabled),
          do: Store.count(ctx, :user, where(users, [u], u.two_factor_enabled == true))
        ),
      authenticator_app: with_any(ctx, :two_factor, users),
      passkey: with_any(ctx, :passkey, users)
    }
  end

  # Users among `users` with at least one row of `model`.
  defp with_any(ctx, model, users) do
    if Data.model?(ctx, model) do
      ids = select(users, [u], u.id)

      Store.count(
        ctx,
        model,
        from(r in Store.module(ctx, model),
          where: r.user_id in subquery(ids),
          distinct: true,
          select: r.user_id
        )
      )
    end
  end

  @doc "The rows of a CSV export: one per day."
  def daily_rows(report) do
    failed = Map.new(report.failed_sign_ins || [], &{&1.day, &1.count})
    active = Map.new(report.active_users, &{&1.day, &1.count})
    sign_ins = Map.new(report.sign_ins, &{&1.day, &1.count})

    for %{day: day, count: sign_ups} <- report.sign_ups do
      [day, sign_ups, Map.get(sign_ins, day, 0), Map.get(active, day, 0), Map.get(failed, day)]
    end
  end
end
