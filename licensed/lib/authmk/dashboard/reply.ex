defmodule Authmk.Dashboard.Reply do
  @moduledoc false
  # How the dashboard's API answers: JSON bodies, errors, pages of rows, and
  # the results of authmk endpoints it runs for the admin.

  import Plug.Conn

  alias Authmk.{Context, Error, Router}
  alias Authmk.Dashboard.{Access, Audit, Data}

  def json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end

  def error(conn, status, code, message),
    do: json(conn, status, %{error: %{code: code, message: message}})

  def not_found(conn, what \\ "page"), do: error(conn, 404, "not_found", "No such #{what}.")

  def forbidden(conn), do: error(conn, 403, "forbidden", "Your role doesn't allow this.")

  def from_error(conn, %Error{} = error),
    do: error(conn, error.status, Atom.to_string(error.code), error.message)

  @doc "A page of `rows` (fetched with one extra, to know whether there's more)."
  def page(conn, rows, key) do
    size = Data.page_size()
    json(conn, 200, %{key => Enum.take(rows, size), :has_more => length(rows) > size})
  end

  @doc "The `offset` query parameter, bounded."
  def offset(conn) do
    case Integer.parse(conn.query_params["offset"] || "0") do
      {offset, ""} when offset >= 0 -> min(offset, 100_000)
      _invalid -> 0
    end
  end

  @doc "A query or body parameter, `nil` when blank."
  def param(conn, name) do
    case Map.get(body(conn), name) || conn.query_params[name] do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  @doc "The JSON body (an object), or an empty map."
  def body(%Plug.Conn{body_params: %{} = params}) when not is_struct(params), do: params
  def body(_conn), do: %{}

  @doc """
  Runs `fun` when the admin holds `permissions`, then answers with what it
  returned: `:ok` or `{:ok, body}` (200, and `event`, `{name, details}`,
  goes to the audit log), or `{:error, error}`.
  """
  def permitted(conn, ctx, admin, permissions, event, fun) do
    if Access.can?(ctx, admin, permissions),
      do: done(conn, ctx, admin, event, fun.()),
      else: forbidden(conn)
  end

  @doc """
  Runs the authmk endpoint `name` as the admin, with `params` (string
  keys): its own checks and hooks decide. Cookies it sets (an
  impersonation) go on the response.
  """
  def run_endpoint(conn, %Context{} = ctx, admin, name, params, event) do
    case Router.run_endpoint(ctx, name, params) do
      {:error, :not_found} ->
        error(conn, 404, "not_available", "This app has turned that action off.")

      {_ctx, {:ok, body, result_ctx}} ->
        conn = Router.put_resp_cookies(conn, result_ctx)
        done(conn, ctx, admin, event, {:ok, body})

      {_ctx, {:error, %Error{} = error, _result_ctx}} ->
        from_error(conn, error)

      {_ctx, {:error, %Error{} = error}} ->
        from_error(conn, error)
    end
  end

  # `event` is `{name, details}` for the audit log, written once it's done.
  defp done(conn, ctx, admin, event, :ok), do: done(conn, ctx, admin, event, {:ok, %{}})

  defp done(conn, ctx, admin, {name, details}, {:ok, body}) do
    :ok = Audit.record(ctx, admin, name, details)
    json(conn, 200, Map.put(body, :ok, true))
  end

  defp done(conn, _ctx, _admin, _event, {:error, %Error{} = error}), do: from_error(conn, error)
end
