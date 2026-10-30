defmodule Authmk.Test.DashboardHelpers do
  @moduledoc false
  # Requests to the dashboard the way an app mounts it (`forward "/admin"`),
  # signed in as a user, from the dashboard's own page (its Origin) or not.

  alias Authmk.Plugins.AuditLog
  alias Authmk.Testing

  @origin {"origin", "http://localhost:4000"}

  def dashboard(auth, method, path, user \\ nil, opts \\ []) do
    body = if opts[:body], do: JSON.encode!(opts[:body]), else: nil
    conn = Plug.Test.conn(method, "/admin" <> path, body)

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    headers = if opts[:origin] == false, do: [], else: [@origin]
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    conn = if user, do: Testing.sign_in(conn, auth, user), else: conn
    segments = tl(conn.path_info)
    Plug.forward(conn, segments, Authmk.Dashboard, Authmk.Dashboard.init(auth: auth))
  end

  @doc "GET or POST `api/<path>`; POSTs carry `body` as JSON."
  def api(auth, method, path, user, opts \\ []),
    do: dashboard(auth, method, "/api/" <> path, user, opts)

  def get_json(auth, path, user) do
    conn = api(auth, :get, path, user)
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  def post_json(auth, path, user, body \\ %{}) do
    conn = api(auth, :post, path, user, body: body)
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  @doc "The audit log's `dashboard.*` events, newest first."
  def dashboard_events(auth) do
    for %{event: "dashboard." <> _} = event <-
          AuditLog.list_events(auth, limit: 100).events,
        do: event
  end
end
