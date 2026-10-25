defmodule Authmk.Test.Browser do
  @moduledoc false
  # Emulates a browser talking to an auth module mounted at /auth: it keeps a
  # cookie jar between requests and sends an Origin header on POSTs.

  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  # `host` is the Host header, like "app.example.com" or "localhost:4000".
  defstruct [:auth, :host, origin: "http://localhost:4000", cookies: %{}, headers: []]

  def new(auth, opts \\ []), do: struct!(%__MODULE__{auth: auth}, opts)

  def get(browser, path, params \\ %{}), do: request(browser, :get, path, params)
  def post(browser, path, params \\ %{}), do: request(browser, :post, path, params)

  @doc "Sends a request and returns the browser with updated cookies, and the conn."
  def request(%__MODULE__{} = browser, method, path, params) do
    conn =
      method
      |> build_conn(path, params)
      |> put_cookies(browser.cookies)
      |> put_headers(browser.headers)
      |> put_origin(method, browser.origin)
      |> put_host(browser.host)

    [_base | segments] = conn.path_info
    conn = Plug.forward(conn, segments, browser.auth, browser.auth.init([]))

    {%{browser | cookies: update_jar(browser.cookies, conn.resp_cookies)}, conn}
  end

  @doc "Decoded JSON body of a response."
  def json(conn), do: JSON.decode!(conn.resp_body)

  @doc "Location header of a redirect."
  def redirected_to(conn) do
    302 = conn.status
    [location] = get_resp_header(conn, "location")
    location
  end

  @doc "The browser's cookie named `name`."
  def cookie(browser, name), do: browser.cookies[name]

  defp build_conn(:get, path, params) do
    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    Plug.Test.conn(:get, "/auth" <> path <> query)
  end

  defp build_conn(method, path, params) do
    method
    |> Plug.Test.conn("/auth" <> path, JSON.encode!(params))
    |> put_req_header("content-type", "application/json")
  end

  defp put_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, value}, conn ->
      Plug.Test.put_req_cookie(conn, name, value)
    end)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  # Adapters turn the Host header into conn.host and conn.port.
  defp put_host(conn, nil), do: conn

  defp put_host(conn, host) do
    case String.split(host, ":") do
      [host, port] -> %{conn | host: host, port: String.to_integer(port)}
      [host] -> %{conn | host: host, port: 80}
    end
  end

  defp put_origin(conn, :get, _origin), do: conn
  defp put_origin(conn, _method, nil), do: conn
  defp put_origin(conn, _method, origin), do: put_req_header(conn, "origin", origin)

  defp update_jar(jar, resp_cookies) do
    Enum.reduce(resp_cookies, jar, fn
      {name, %{max_age: 0}}, jar -> Map.delete(jar, name)
      {name, %{value: value}}, jar -> Map.put(jar, name, value)
    end)
  end
end
