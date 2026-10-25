defmodule Authmk.Origin do
  @moduledoc """
  Origin checks for requests and redirect targets.

  State-changing requests are rejected when they come from an untrusted
  origin (CSRF protection). Redirects only go to relative paths or trusted
  origins (open-redirect protection). Trusted origins are `base_url`, the
  `trusted_origins` config and whatever plugins add.
  """

  alias Authmk.{Config, Context, Error}

  @safe_methods ["GET", "HEAD", "OPTIONS"]

  @doc """
  Checks the request's `Origin` (or `Referer`) header.

  Browsers send `Origin` on every cross-site POST. Requests with neither
  header are only allowed when they carry no cookies, which means they come
  from a non-browser client and can't be forged.
  """
  @spec check_request(Context.t()) :: :ok | {:error, Error.t()}
  def check_request(%Context{conn: conn, config: config}) do
    cond do
      conn.method in @safe_methods ->
        :ok

      config.advanced[:disable_origin_check] ->
        :ok

      origin = request_origin(conn) ->
        if trusted?(config, origin), do: :ok, else: invalid_origin()

      conn.req_cookies == %{} ->
        :ok

      true ->
        invalid_origin()
    end
  end

  @doc "Whether `url` is a safe redirect target. `nil` counts as safe (no redirect)."
  @spec safe_redirect?(Config.t(), String.t() | nil) :: boolean()
  def safe_redirect?(_config, nil), do: true

  def safe_redirect?(config, url) when is_binary(url) do
    cond do
      String.match?(url, ~r/[\x00-\x20\\]/) -> false
      String.starts_with?(url, "//") -> false
      String.starts_with?(url, "/") -> true
      origin = origin(url) -> trusted?(config, origin)
      true -> false
    end
  end

  @doc "`:ok` when `url` is a safe redirect, otherwise an `:invalid_callback_url` error."
  @spec check_redirect(Config.t(), String.t() | nil) :: :ok | {:error, Error.t()}
  def check_redirect(config, url) do
    if safe_redirect?(config, url), do: :ok, else: {:error, Error.new(:invalid_callback_url)}
  end

  @doc "Whether `origin` is in the trusted list."
  @spec trusted?(Config.t(), String.t()) :: boolean()
  def trusted?(config, origin), do: origin in config.trusted_origins

  @doc "Normalizes a URL to its origin. Raises when `url` has no scheme or host."
  @spec normalize!(String.t()) :: String.t()
  def normalize!(url) do
    case origin(url) do
      nil -> raise ArgumentError, "#{inspect(url)} is not a valid origin"
      origin -> origin
    end
  end

  @doc "`scheme://host[:port]` of a URL, lowercased, or `nil`."
  @spec origin(String.t()) :: String.t() | nil
  def origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        String.downcase("#{scheme}://#{host}") <> port_suffix(scheme, port)

      _ ->
        nil
    end
  end

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  # The origin the request claims to come from, `"invalid"` when the header
  # can't be parsed (including the literal `null`), or `nil` without headers.
  defp request_origin(conn) do
    case header(conn, "origin") || header(conn, "referer") do
      nil -> nil
      value -> origin(value) || "invalid"
    end
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp invalid_origin, do: {:error, Error.new(:invalid_origin)}
end
