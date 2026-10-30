defmodule Authmk.Plugins.AuditLog do
  @moduledoc """
  An audit log: who did what to which account, when, and from where.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.AuditLog, can_view_all: &MyApp.Auth.admin?/1}], ...

  Events are recorded as authmk writes: users created, updated and deleted;
  sessions started and ended; accounts linked, changed (like a new
  password) and unlinked; verifications issued (by purpose); and with
  `Authmk.Plugins.Organization`, organizations, members and invitations.
  Each has the user it's about, the signed-in user who caused it (`actor`),
  the organization, IP address and user agent, and a few safe details
  (`metadata`): ids, roles, providers, purposes. Never tokens, codes or
  passwords.

  | Method | Path | Session |
  |---|---|---|
  | GET | `/audit-log/list` | required (the user's own events) |
  | GET | `/audit-log/list-all` | required (`can_view_all`) |

  Both take `limit` (at most 100), `offset` and `event`; the second also
  `user_id` and `organization_id`. From server code, use `list_events/2`.

  Every event is also emitted as `[:authmk, :audit_log, :event]` telemetry
  and given to each of `destinations`, to ship to your log pipeline. Events
  older than `retention_days` are deleted, at most once an hour per node,
  or when you call `prune/1`.

  ## Options

    * `:can_view_all` - `fn ctx -> boolean end`: who may read everyone's
      events. Without it, no one can through the endpoint.
    * `:retention_days` - default 90; `nil` keeps events forever.
    * `:events` - event names to record (default: all).
    * `:destinations` - functions of one argument (the event map), called
      for every event, like `&MyApp.Audit.ship/1`. Errors are logged, never
      raised: a broken destination doesn't stop sign-ins.
  """

  use Authmk.Plugin

  import Ecto.Query

  alias Authmk.{Background, Context, Endpoint, Error, Log, Request, Store}
  alias Authmk.Storage.ETS

  @models [:user, :session, :account, :verification, :organization, :member, :invitation]
  @actions %{after_create: "created", after_update: "updated", after_delete: "deleted"}
  @cleanup_every 3600

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      can_view_all: [type: {:fun, 1}],
      retention_days: [type: {:or, [:pos_integer, nil]}, default: 90],
      events: [type: {:or, [{:in, [:all]}, {:list, :string}]}, default: :all],
      destinations: [type: {:list, {:fun, 1}}, default: []]
    )
  end

  @impl true
  def schema(_opts) do
    %{
      audit_event: [
        plural: "audit_events",
        fields: [
          event: [type: :string, required: true, index: true, input: false],
          # Without foreign keys: events outlive what they're about.
          user_id: [type: :string, index: true, input: false],
          actor_id: [type: :string, input: false],
          # "user", or "service_account" for programs (Authmk.Plugins.ServiceAccount).
          actor_type: [type: :string, input: false],
          organization_id: [type: :string, index: true, input: false],
          ip_address: [type: :string, input: false],
          user_agent: [type: :string, input: false],
          # JSON
          metadata: [type: :text, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    filters = [
      limit: [type: :integer, default: 50],
      offset: [type: :integer, default: 0],
      event: [type: :string]
    ]

    [
      Endpoint.new(
        name: :audit_log_list,
        method: :get,
        path: "/audit-log/list",
        handler: {__MODULE__, :list},
        session: :required,
        params: filters
      ),
      Endpoint.new(
        name: :audit_log_list_all,
        method: :get,
        path: "/audit-log/list-all",
        handler: {__MODULE__, :list_all},
        session: :required,
        params: filters ++ [user_id: [type: :string], organization_id: [type: :string]]
      )
    ]
  end

  @impl true
  def database_hook(event, model, record, ctx)
      when model in @models and is_map_key(@actions, event) do
    name = event_name(model, @actions[event], record)
    if name, do: record(ctx, name, details(model, record))
    {:ok, record}
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  # Sign-outs and revocations end sessions without a delete of each row.
  @impl true
  def sessions_ended(user_id, sessions, ctx) do
    for session <- sessions,
        do:
          record(ctx, "session.ended", %{
            user_id: user_id,
            metadata: %{session_id: to_string(session.id)}
          })

    :ok
  end

  defp event_name(:member, "created", _record), do: "member.added"
  defp event_name(:member, "deleted", _record), do: "member.removed"
  defp event_name(:account, "created", _record), do: "account.linked"
  defp event_name(:account, "deleted", _record), do: "account.unlinked"
  defp event_name(:session, "created", _record), do: "session.created"
  defp event_name(:session, _action, _record), do: nil
  defp event_name(:verification, "created", _record), do: "verification.created"
  defp event_name(:verification, _action, _record), do: nil
  defp event_name(model, action, _record), do: "#{model}.#{action}"

  # Only what's safe to keep: ids, roles, providers, purposes.
  defp details(:user, user), do: %{user_id: user.id}

  defp details(:session, session),
    do: %{
      user_id: session.user_id,
      metadata: %{session_id: session.id, impersonated_by: Map.get(session, :impersonated_by_id)}
    }

  defp details(:account, account),
    do: %{user_id: account.user_id, metadata: %{provider_id: account.provider_id}}

  defp details(:verification, verification),
    do: %{metadata: %{purpose: verification.identifier |> String.split(":") |> hd()}}

  defp details(:organization, organization),
    do: %{organization_id: organization.id, metadata: %{slug: Map.get(organization, :slug)}}

  defp details(:member, member),
    do: %{
      user_id: member.user_id,
      organization_id: member.organization_id,
      metadata: %{role: member.role}
    }

  defp details(:invitation, invitation),
    do: %{
      organization_id: invitation.organization_id,
      metadata: %{email: invitation.email, role: invitation.role, status: invitation.status}
    }

  @doc """
  Records an event of your own, like `"billing.plan_changed"`: `details`
  may hold `:user_id`, `:organization_id` and `:metadata` (a map, kept as
  JSON; leave secrets out).
  """
  @spec record(Context.t(), String.t(), map()) :: :ok
  def record(%Context{} = ctx, name, details) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    if opts[:events] == :all or name in opts[:events] do
      {actor_type, actor_id} = actor(ctx, details[:actor])

      attrs = %{
        event: name,
        user_id: id(details[:user_id]),
        actor_id: actor_id,
        actor_type: actor_type,
        organization_id: id(details[:organization_id]),
        ip_address: ctx.conn && Request.client_ip(ctx),
        user_agent: ctx.conn && truncate(Request.user_agent(ctx)),
        metadata: JSON.encode!(Map.reject(details[:metadata] || %{}, fn {_k, v} -> is_nil(v) end))
      }

      _delivered =
        case Store.insert(ctx, :audit_event, attrs) do
          {:ok, event} -> deliver(ctx, opts, to_map(event))
          {:error, error} -> Log.warning("audit event #{name} not recorded: #{error.code}")
        end

      cleanup(ctx, opts)
    end

    :ok
  end

  # Who did it: the signed-in user, or the service account behind the
  # request; `details[:actor]` names one from server code.
  defp actor(%Context{user: user} = ctx, nil) when not is_nil(user), do: actor(ctx, user)

  defp actor(%Context{private: %{principal: principal}} = ctx, nil) when not is_nil(principal),
    do: actor(ctx, principal)

  defp actor(_ctx, nil), do: {nil, nil}

  defp actor(ctx, %{__struct__: module, id: id}) do
    type = if module == Store.module(ctx, :user), do: "user", else: "service_account"
    {type, id(id)}
  end

  @doc """
  Records an event from your own code, outside a request to authmk: like
  what a service account did through your API.

      AuditLog.log(MyApp.Auth, "report.exported",
        actor: conn.assigns.current_principal,
        organization_id: org.id,
        metadata: %{format: "csv"}
      )

  `opts`: `:actor` (a user or a service account), `:user_id`,
  `:organization_id`, `:metadata`, and `:conn` for the address and user
  agent.
  """
  @spec log(module(), String.t(), keyword()) :: :ok
  def log(auth, name, opts \\ []) do
    ctx = %{Context.new(auth.config()) | conn: opts[:conn]}
    record(ctx, name, Map.new(opts))
  end

  defp deliver(ctx, opts, event) do
    :telemetry.execute([:authmk, :audit_log, :event], %{}, %{auth: ctx.config.auth, event: event})

    for destination <- opts[:destinations] do
      try do
        destination.(event)
      rescue
        exception -> Log.warning("audit destination failed: #{inspect(exception.__struct__)}")
      end
    end
  end

  # Old events go, at most once an hour on this node, in the background.
  defp cleanup(%Context{config: config} = ctx, opts) do
    table = [table: ETS.table(config.auth)]

    if opts[:retention_days] && is_nil(ETS.get(table, "audit-log-cleanup")) do
      :ok = ETS.put(table, "audit-log-cleanup", "1", @cleanup_every)
      Background.call(ctx, __MODULE__, :delete_expired, [opts[:retention_days]])
    end

    :ok
  end

  @doc """
  Deletes events older than `retention_days` now, for apps that prefer a
  scheduled job. Returns how many went.
  """
  @spec prune(module()) :: non_neg_integer()
  def prune(auth) do
    ctx = Context.new(auth.config())

    case Context.plugin_opts(ctx, __MODULE__)[:retention_days] do
      nil -> 0
      days -> delete_expired(ctx, days)
    end
  end

  @doc false
  # Background work: see `Authmk.Background`.
  def delete_expired(ctx, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)
    Store.delete_all(ctx, :audit_event, dynamic([e], e.inserted_at < ^cutoff))
  end

  @doc false
  def list(%Context{params: params, user: user} = ctx) do
    {:ok, query(ctx, params, %{user_id: id(user.id)}), ctx}
  end

  @doc false
  def list_all(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    if opts[:can_view_all] && opts[:can_view_all].(ctx) == true do
      filters = %{user_id: params.user_id, organization_id: params.organization_id}
      {:ok, query(ctx, params, filters), ctx}
    else
      {:error, Error.new(:forbidden)}
    end
  end

  @doc """
  Events, newest first. Filters: `:user_id`, `:organization_id`, `:event`;
  `:limit` (at most 100) and `:offset`.
  """
  @spec list_events(module(), keyword()) :: %{events: [map()], total: non_neg_integer()}
  def list_events(auth, filters \\ []) do
    ctx = Context.new(auth.config())

    params = %{
      limit: filters[:limit] || 50,
      offset: filters[:offset] || 0,
      event: filters[:event]
    }

    query(ctx, params, %{
      user_id: id(filters[:user_id]),
      organization_id: id(filters[:organization_id])
    })
  end

  defp query(ctx, params, filters) do
    base =
      Enum.reduce(
        Map.put(filters, :event, params.event),
        from(e in Store.module(ctx, :audit_event)),
        fn
          {_field, nil}, query -> query
          {field, value}, query -> where(query, [e], field(e, ^field) == ^value)
        end
      )

    limit = params.limit |> max(1) |> min(100)

    events =
      Store.list(
        ctx,
        :audit_event,
        base
        |> order_by([e], desc: e.inserted_at, desc: e.id)
        |> limit(^limit)
        |> offset(^max(params.offset, 0))
      )

    %{events: Enum.map(events, &to_map/1), total: Store.count(ctx, :audit_event, base)}
  end

  defp to_map(event) do
    %{
      id: to_string(event.id),
      event: event.event,
      user_id: event.user_id,
      actor_id: event.actor_id,
      actor_type: event.actor_type,
      organization_id: event.organization_id,
      ip_address: event.ip_address,
      user_agent: event.user_agent,
      metadata: JSON.decode!(event.metadata || "{}"),
      created_at: event.inserted_at
    }
  end

  defp id(nil), do: nil
  defp id(value), do: to_string(value)

  defp truncate(nil), do: nil
  defp truncate(agent), do: String.slice(agent, 0, 255)
end
