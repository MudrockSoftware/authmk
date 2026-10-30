defmodule Authmk.Router do
  @moduledoc """
  Serves auth endpoints. Every auth module is a Plug that calls this router;
  mount it with `forward "/auth", MyApp.Auth`.

  Each request goes through, in order: endpoint lookup, `on_request` hooks,
  origin check, rate limit, param validation, session loading, the
  endpoint's middleware, `before_endpoint` hooks, the handler, and
  `after_endpoint` hooks. `on_response` hooks run just before the response
  is sent.

  Error results are passed to the auth module's `on_api_error/2`. Exceptions
  are logged and answered with a JSON `internal_error`, or re-raised to your
  Plug/Phoenix error handling with `errors: [rescue: false]`.

  Each request emits `[:authmk, :endpoint, :start | :stop | :exception]`
  telemetry events.
  """

  import Plug.Conn

  alias Authmk.{
    BaseURL,
    Config,
    Context,
    Endpoint,
    Error,
    Hooks,
    Log,
    Origin,
    Params,
    RateLimit,
    Sessions
  }

  @parsers Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)

  @doc "Handles a request for the `auth` module."
  @spec call(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def call(conn, auth) do
    config = Config.fetch!(auth)

    case read_request(conn) do
      {:ok, conn} -> route(conn, config)
      {:error, conn, status} -> send_error(conn, unreadable(status))
    end
  end

  # Bodies and query strings that can't be read (bad encoding, malformed,
  # too large) get the client error Plug gives them, as JSON.
  defp read_request(conn) do
    {:ok, conn |> fetch_cookies() |> fetch_query_params() |> parse_body()}
  rescue
    exception ->
      status = Plug.Exception.status(exception)
      if status in 400..499, do: {:error, conn, status}, else: reraise(exception, __STACKTRACE__)
  end

  defp unreadable(status),
    do: Error.custom(:invalid_request, status, "The request couldn't be read")

  defp route(conn, config) do
    with :not_page_file <- page_file(conn),
         :not_preflight <- preflight(conn, config),
         {:ok, base_url} <- BaseURL.resolve(config, conn),
         {endpoint, path_params} <- find_endpoint(config, conn) do
      serve(conn, %Context{config: config, conn: conn, base_url: base_url}, endpoint, path_params)
    else
      {:preflight, conn} -> conn
      {:page_file, conn} -> conn
      {:error, %Error{} = error} -> send_error(conn, error)
      nil -> send_json(conn, 404, Error.to_map(Error.new(:not_found)))
    end
  end

  # The files of authmk's own pages (Authmk.Pages), next to them.
  @page_files Plug.Static.init(
                at: "/",
                from: {:authmk, "priv/pages"},
                only: ["_app", "favicon.svg"]
              )

  defp page_file(%Plug.Conn{method: "GET", path_info: [first | _]} = conn)
       when first in ["_app", "favicon.svg"] do
    case Plug.Static.call(conn, @page_files) do
      %Plug.Conn{halted: true} = conn -> {:page_file, conn}
      conn -> {:page_file, conn |> send_resp(404, "Not found") |> halt()}
    end
  end

  defp page_file(_conn), do: :not_page_file

  # CORS preflight, for endpoints that allow it. They never use cookies, so
  # any origin may call them, without credentials.
  defp preflight(%Plug.Conn{method: "OPTIONS"} = conn, config) do
    methods =
      for endpoint <- config.endpoints,
          endpoint.cors,
          Endpoint.path_matches?(endpoint, conn.path_info),
          do: endpoint.method |> Atom.to_string() |> String.upcase()

    if methods == [] do
      :not_preflight
    else
      conn =
        conn
        |> cors_headers()
        |> put_resp_header("access-control-allow-methods", Enum.join(["OPTIONS" | methods], ", "))
        |> put_resp_header("access-control-allow-headers", "authorization, content-type, dpop")
        |> put_resp_header("access-control-max-age", "600")
        |> send_resp(204, "")

      {:preflight, conn}
    end
  end

  defp preflight(_conn, _config), do: :not_preflight

  defp cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-expose-headers", "www-authenticate, dpop-nonce")
  end

  @doc "Applies the context's cookie changes to the conn."
  @spec put_resp_cookies(Plug.Conn.t(), Context.t()) :: Plug.Conn.t()
  def put_resp_cookies(conn, %Context{resp_cookies: cookies}) do
    Enum.reduce(cookies, conn, fn
      {name, :delete, opts}, conn -> delete_resp_cookie(conn, name, opts)
      {name, value, opts}, conn -> put_resp_cookie(conn, name, value, opts)
    end)
  end

  defp serve(conn, %Context{config: config} = ctx, endpoint, path_params) do
    raw_params = conn.query_params |> Map.merge(conn.body_params) |> Map.merge(path_params)
    ctx = %{ctx | endpoint: endpoint, raw_params: raw_params}
    metadata = %{auth: config.auth, endpoint: endpoint.name}

    {ctx, result} =
      :telemetry.span([:authmk, :endpoint], metadata, fn ->
        {ctx, result} = run_safely(ctx)
        {{ctx, result}, Map.put(metadata, :result, elem(result, 0))}
      end)

    report_error(ctx, result)
    respond(conn, ctx, result)
  end

  defp run_safely(%Context{config: config} = ctx) do
    run(ctx)
  rescue
    exception ->
      if not config.errors[:rescue], do: reraise(exception, __STACKTRACE__)

      Log.error(
        "#{ctx.endpoint.path} crashed:\n" <> Exception.format(:error, exception, __STACKTRACE__)
      )

      {Context.put_private(ctx, :exception, exception), {:error, Error.new(:internal_error)}}
  end

  defp finish(ctx, result) do
    result = Hooks.after_endpoint(ctx, result)
    {result_ctx(result, ctx), result}
  end

  defp run(ctx) do
    with {:cont, ctx} <- Hooks.on_request(ctx),
         :ok <- Origin.check_request(ctx),
         :ok <- RateLimit.check(ctx),
         {:ok, params} <- Params.cast(ctx.endpoint.params, ctx.raw_params),
         {:ok, ctx} <- load_session(%{ctx | params: params}),
         {:cont, ctx} <- run_middleware(ctx),
         {:cont, ctx} <- Hooks.before_endpoint(ctx) do
      {module, function} = ctx.endpoint.handler
      finish(ctx, apply(module, function, [ctx]))
    else
      {:respond, result, hook_ctx} -> finish(hook_ctx, result)
      {:halt, %Error{} = error} -> {ctx, {:error, error}}
      {:error, %Error{} = error} -> {ctx, {:error, error}}
    end
  end

  # Middleware the endpoint declares, in order. Each returns `{:cont, ctx}`
  # or `{:halt, error}`.
  defp run_middleware(%Context{endpoint: endpoint} = ctx) do
    Enum.reduce_while(endpoint.middleware, {:cont, ctx}, fn {module, function}, {:cont, ctx} ->
      case apply(module, function, [ctx]) do
        {:cont, %Context{} = ctx} -> {:cont, {:cont, ctx}}
        {:halt, %Error{} = error} -> {:halt, {:halt, error}}
      end
    end)
  end

  defp result_ctx({:ok, _body, ctx}, _ctx), do: ctx
  defp result_ctx({:redirect, _url, ctx}, _ctx), do: ctx
  defp result_ctx({:html, _status, _html, ctx}, _ctx), do: ctx
  defp result_ctx({:json, _status, _body, ctx}, _ctx), do: ctx
  defp result_ctx({:error, _error, ctx}, _ctx), do: ctx
  defp result_ctx({:error, _error}, ctx), do: ctx

  defp load_session(%Context{endpoint: %Endpoint{session: :none}} = ctx), do: {:ok, ctx}

  defp load_session(%Context{endpoint: endpoint} = ctx) do
    use_cache = endpoint.cookie_cache and not Map.get(ctx.params, :disable_cookie_cache, false)
    ctx = Sessions.load(ctx, cache: use_cache)

    cond do
      ctx.private[:authentication_error] -> {:error, ctx.private[:authentication_error]}
      endpoint.session == :required and is_nil(ctx.session) -> {:error, Error.new(:unauthorized)}
      endpoint.fresh and not Sessions.fresh?(ctx) -> {:error, Error.new(:session_not_fresh)}
      true -> {:ok, ctx}
    end
  end

  # The auth module hears about every error; for crashes, the exception.
  defp report_error(ctx, {:error, error}), do: notify(ctx, error)
  defp report_error(ctx, {:error, error, _ctx}), do: notify(ctx, error)
  defp report_error(_ctx, _success), do: :ok

  defp notify(ctx, error), do: ctx.config.auth.on_api_error(ctx.private[:exception] || error, ctx)

  defp respond(conn, ctx, result) do
    conn =
      conn
      |> put_resp_cookies(ctx)
      |> merge_resp_headers(ctx.resp_headers)
      |> then(&if(ctx.endpoint && ctx.endpoint.cors, do: cors_headers(&1), else: &1))
      |> register_before_send(&Hooks.on_response(&1, ctx))

    case result do
      {:ok, body, _ctx} ->
        send_json(conn, 200, body)

      {:redirect, url, _ctx} ->
        conn |> put_resp_header("location", url) |> send_resp(302, "")

      # HTML, or another type the handler set (like SAML's XML metadata).
      {:html, status, html, _ctx} ->
        conn |> default_content_type("text/html") |> send_resp(status, html)

      # For protocols with their own JSON (like OAuth's errors).
      {:json, status, body, _ctx} ->
        send_json(conn, status, body)

      {:error, error, _ctx} ->
        send_error(conn, error)

      {:error, error} ->
        send_error(conn, error)
    end
  end

  defp send_error(conn, %Error{code: :rate_limited} = error) do
    conn
    |> put_resp_header("retry-after", to_string(error.details.retry_after))
    |> send_json(error.status, Error.to_map(error))
  end

  defp send_error(conn, %Error{} = error), do: send_json(conn, error.status, Error.to_map(error))

  # Protocols with their own JSON type (SCIM's) set it on the context.
  defp send_json(conn, status, body),
    do: conn |> default_content_type("application/json") |> send_resp(status, JSON.encode!(body))

  defp default_content_type(conn, type) do
    if get_resp_header(conn, "content-type") == [],
      do: put_resp_content_type(conn, type),
      else: conn
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
