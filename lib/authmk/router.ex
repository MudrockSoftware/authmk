defmodule Authmk.Router do
  @moduledoc """
  Serves auth endpoints. Every auth module is a Plug that calls this router;
  mount it with `forward "/auth", MyApp.Auth`.

  Each request goes through, in order: endpoint lookup, origin check, rate
  limit, param validation, session loading, `before_endpoint` hooks, the
  handler, and `after_endpoint` hooks. Each request emits
  `[:authmk, :endpoint, :start | :stop | :exception]` telemetry events.
  """

  import Plug.Conn

  alias Authmk.{Config, Context, Endpoint, Error, Hooks, Origin, Params, RateLimit, Sessions}

  @parsers Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)

  @doc "Handles a request for the `auth` module."
  @spec call(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def call(conn, auth) do
    config = Config.fetch!(auth)
    conn = conn |> fetch_cookies() |> fetch_query_params() |> parse_body()

    case find_endpoint(config, conn) do
      {endpoint, path_params} -> serve(conn, config, endpoint, path_params)
      nil -> send_json(conn, 404, Error.to_map(Error.new(:not_found)))
    end
  end

  @doc "Applies the context's cookie changes to the conn."
  @spec put_resp_cookies(Plug.Conn.t(), Context.t()) :: Plug.Conn.t()
  def put_resp_cookies(conn, %Context{resp_cookies: cookies}) do
    Enum.reduce(cookies, conn, fn
      {name, :delete, opts}, conn -> delete_resp_cookie(conn, name, opts)
      {name, value, opts}, conn -> put_resp_cookie(conn, name, value, opts)
    end)
  end

  defp serve(conn, config, endpoint, path_params) do
    raw_params = conn.query_params |> Map.merge(conn.body_params) |> Map.merge(path_params)
    ctx = %Context{config: config, conn: conn, endpoint: endpoint, raw_params: raw_params}
    metadata = %{auth: config.auth, endpoint: endpoint.name}

    {ctx, result} =
      :telemetry.span([:authmk, :endpoint], metadata, fn ->
        {ctx, result} = run(ctx)
        {{ctx, result}, Map.put(metadata, :result, elem(result, 0))}
      end)

    respond(conn, ctx, result)
  end

  defp run(ctx) do
    with :ok <- Origin.check_request(ctx),
         :ok <- RateLimit.check(ctx),
         {:ok, params} <- Params.cast(ctx.endpoint.params, ctx.raw_params),
         {:ok, ctx} <- load_session(%{ctx | params: params}),
         {:cont, ctx} <- Hooks.before_endpoint(ctx) do
      {module, function} = ctx.endpoint.handler
      result = Hooks.after_endpoint(ctx, apply(module, function, [ctx]))
      {result_ctx(result, ctx), result}
    else
      {:halt, %Error{} = error} -> {ctx, {:error, error}}
      {:error, %Error{} = error} -> {ctx, {:error, error}}
    end
  end

  defp result_ctx({:ok, _body, ctx}, _ctx), do: ctx
  defp result_ctx({:redirect, _url, ctx}, _ctx), do: ctx
  defp result_ctx({:error, _error, ctx}, _ctx), do: ctx
  defp result_ctx({:error, _error}, ctx), do: ctx

  defp load_session(%Context{endpoint: %Endpoint{session: :none}} = ctx), do: {:ok, ctx}

  defp load_session(%Context{endpoint: endpoint} = ctx) do
    use_cache = endpoint.cookie_cache and not Map.get(ctx.params, :disable_cookie_cache, false)
    ctx = Sessions.load(ctx, cache: use_cache)

    cond do
      endpoint.session == :required and is_nil(ctx.session) -> {:error, Error.new(:unauthorized)}
      endpoint.fresh and not Sessions.fresh?(ctx) -> {:error, Error.new(:session_not_fresh)}
      true -> {:ok, ctx}
    end
  end

  defp respond(conn, ctx, result) do
    conn = put_resp_cookies(conn, ctx)

    case result do
      {:ok, body, _ctx} -> send_json(conn, 200, body)
      {:redirect, url, _ctx} -> conn |> put_resp_header("location", url) |> send_resp(302, "")
      {:error, error, _ctx} -> send_error(conn, error)
      {:error, error} -> send_error(conn, error)
    end
  end

  defp send_error(conn, %Error{code: :rate_limited} = error) do
    conn
    |> put_resp_header("retry-after", to_string(error.details.retry_after))
    |> send_json(error.status, Error.to_map(error))
  end

  defp send_error(conn, %Error{} = error), do: send_json(conn, error.status, Error.to_map(error))

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp find_endpoint(config, conn) do
    Enum.find_value(config.endpoints, fn endpoint ->
      case Endpoint.match(endpoint, conn.method, conn.path_info) do
        {:ok, path_params} -> {endpoint, path_params}
        :error -> nil
      end
    end)
  end

  defp parse_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn),
    do: Plug.Parsers.call(conn, @parsers)

  defp parse_body(conn), do: conn
end
