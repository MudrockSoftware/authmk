defmodule Authmk.Origin do
  @moduledoc """
  Origin checks for requests and redirect targets.

  State-changing requests from untrusted origins are rejected (CSRF
  protection), and redirects only go to safe relative paths or trusted
  origins (open-redirect protection).

  Trusted origins are `base_url`, the `trusted_origins` config, what plugins
  add, and what the auth module's `dynamic_trusted_origins/1` returns for
  the request. Entries can be:

    * exact origins: `"https://app.example.com"`
    * wildcards: `"https://*.example.com"` matches the whole origin;
      `"*.example.com"` matches the host with any scheme. `*` matches any
      characters except `/`, `?` matches one such character, `**` matches
      anything.
    * custom schemes, for mobile apps and extensions: `"myapp://"` trusts the
      whole scheme; `"myapp://callback"` only that host, and
      `"myapp://host/path"` only that path and paths below it.
  """

  alias Authmk.{Context, Error}

  @safe_methods ["GET", "HEAD", "OPTIONS"]
  @control_characters ~r/[\x00-\x1f\x7f-\x9f]/u

  @doc """
  Checks the request's `Origin` (or `Referer`) header.

  Browsers send `Origin` on every cross-site POST. Requests with neither
  header are only allowed when they carry no cookies, which means they come
  from a non-browser client and can't be forged.
  """
  @spec check_request(Context.t()) :: :ok | {:error, Error.t()}
  def check_request(%Context{conn: conn, config: config} = ctx) do
    cond do
      conn.method in @safe_methods -> :ok
      config.advanced[:disable_origin_check] -> :ok
      origin = request_origin(conn) -> if trusted?(ctx, origin), do: :ok, else: invalid_origin()
      conn.req_cookies == %{} -> :ok
      true -> invalid_origin()
    end
  end

  @doc "Whether `url` is a safe redirect target. `nil` counts as safe (no redirect)."
  @spec safe_redirect?(Context.t(), String.t() | nil) :: boolean()
  def safe_redirect?(_ctx, nil), do: true
  def safe_redirect?(_ctx, "/" <> _ = url), do: safe_relative?(url)

  def safe_redirect?(ctx, url) when is_binary(url),
    do: not String.match?(url, @control_characters) and trusted?(ctx, url)

  @doc "`:ok` when `url` is a safe redirect, otherwise an `:invalid_callback_url` error."
  @spec check_redirect(Context.t(), String.t() | nil) :: :ok | {:error, Error.t()}
  def check_redirect(ctx, url) do
    if safe_redirect?(ctx, url), do: :ok, else: {:error, Error.new(:invalid_callback_url)}
  end

  @doc "Whether `url` (or an origin) matches a trusted origin."
  @spec trusted?(Context.t(), String.t()) :: boolean()
  def trusted?(%Context{config: config} = ctx, url) do
    patterns = config.trusted_origins ++ config.auth.dynamic_trusted_origins(ctx)
    Enum.any?(patterns, &matches?(url, &1))
  end

  @doc "Whether `url` matches one trusted-origin entry. See the module docs."
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(url, pattern) do
    cond do
      wildcard?(pattern) and String.contains?(pattern, "://") ->
        glob_match?(pattern, origin(url) || url)

      wildcard?(pattern) ->
        host = host(url)
        is_binary(host) and glob_match?(pattern, host)

      http?(url) ->
        origin(url) == normalize(pattern)

      true ->
        custom_scheme_match?(url, pattern)
    end
  end

  @doc """
  Normalizes an http(s) origin (`scheme://host[:port]`, lowercased). Other
  entries (wildcards, custom schemes) are returned unchanged.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(entry) do
    case not wildcard?(entry) and origin(entry) do
      origin when is_binary(origin) -> origin
      _not_an_http_origin -> entry
    end
  end

  @doc "`scheme://host[:port]` of an http(s) URL, lowercased, or `nil`."
  @spec origin(String.t()) :: String.t() | nil
  def origin(url) do
    case parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        String.downcase("#{scheme}://#{host}") <> port_suffix(scheme, port)

      _ ->
        nil
    end
  end

  # Root-relative URLs only. Rejects `//host`, backslashes, control
  # characters and encoded path separators, which browsers or routers may
  # read as another host.
  defp safe_relative?(url) do
    path = url |> String.split(["?", "#"], parts: 2) |> hd()

    not String.starts_with?(url, "//") and
      not String.contains?(url, "\\") and
      not String.match?(url, @control_characters) and
      not String.match?(path, ~r/%2f|%5c/i)
  end

  defp wildcard?(pattern), do: String.contains?(pattern, ["*", "?"])

  defp http?(url), do: String.starts_with?(String.downcase(url), ["http://", "https://"])

  defp host(url) do
    case parse(url) do
      %URI{host: host} when host not in [nil, ""] -> String.downcase(host)
      _ -> nil
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> uri
      {:error, _part} -> nil
    end
  end

  defp glob_match?(pattern, value) do
    regex =
      pattern
      |> String.downcase()
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/\\\\]*")
      |> String.replace("\\?", "[^/\\\\]")

    Regex.match?(~r/\A#{regex}\z/, String.downcase(value))
  end

  defp custom_scheme_match?(url, pattern) do
    with %{} = url <- parse_custom(url),
         %{} = pattern <- parse_custom(pattern),
         true <- url.scheme == pattern.scheme,
         true <- pattern.authority == "" or url.authority == pattern.authority do
      pattern.path == "" or url.path == pattern.path or
        String.starts_with?(url.path, pattern.path <> "/")
    else
      _ -> false
    end
  end

  # Splits `scheme://authority/path` with plain string operations, and
  # resolves `.` and `..` so traversal can't escape a pinned path.
  defp parse_custom(value) do
    with false <- String.match?(value, @control_characters),
         [scheme, rest] when scheme != "" <- String.split(value, ":", parts: 2),
         {authority, path} = split_authority(rest),
         {:ok, path} <- path |> String.split(["?", "#"], parts: 2) |> hd() |> decode() do
      %{
        scheme: String.downcase(scheme),
        authority: String.downcase(authority),
        path: normalize_path(path)
      }
    else
      _ -> nil
    end
  end

  # Malformed percent-encoding makes the URL untrusted.
  defp decode(path) do
    {:ok, URI.decode(path)}
  rescue
    ArgumentError -> :error
  end

  defp split_authority("//" <> rest) do
    case :binary.match(rest, ["/", "?", "#"]) do
      {index, _length} ->
        {binary_part(rest, 0, index), binary_part(rest, index, byte_size(rest) - index)}

      :nomatch ->
        {rest, ""}
    end
  end

  defp split_authority(rest), do: {"", rest}

  defp normalize_path(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.reduce([], fn
        "..", acc -> Enum.drop(acc, 1)
        segment, acc when segment in [".", ""] -> acc
        segment, acc -> [segment | acc]
      end)

    if segments == [], do: "", else: "/" <> Enum.join(Enum.reverse(segments), "/")
  end

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp request_origin(conn), do: header(conn, "origin") || header(conn, "referer")

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp invalid_origin, do: {:error, Error.new(:invalid_origin)}
end
