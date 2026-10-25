defmodule Authmk.BaseURL do
  @moduledoc """
  The app's public URL, for links in emails, origin checks and secure cookies.

  Usually one fixed URL:

      base_url: "https://myapp.com"

  For apps served from several hosts (custom domains, preview deployments),
  an allow list instead:

      base_url: [
        allowed_hosts: ["myapp.com", "www.myapp.com", "*.preview.myapp.com", "localhost:4000"],
        protocol: :auto,                 # or "https" / "http"
        fallback: "https://myapp.com"    # optional
      ]

  Each request's host comes from `x-forwarded-host`, then the `Host` header
  (`conn.host`, with `conn.port` unless it is 80 or 443).
  It must match an allowed host (`*` matches anything but `/`); otherwise the
  request fails with `invalid_host`, unless a fallback is set. Allowed hosts
  are trusted origins automatically. With `protocol: :auto`, the protocol
  comes from `x-forwarded-proto`, then the connection.
  """

  alias Authmk.{Config, Error, Origin}

  @host_format ~r/\A[a-z0-9.-]+(:\d{1,5})?\z/i

  @doc "The base URL for a request (or for server-side calls, with `nil`)."
  @spec resolve(Config.t(), Plug.Conn.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve(%{base_url: url}, _conn) when is_binary(url), do: {:ok, url}

  def resolve(%{base_url: dynamic}, nil), do: fallback(dynamic)

  def resolve(%{base_url: dynamic}, conn) do
    host = request_host(conn)

    if host && Enum.any?(dynamic[:allowed_hosts], &host_matches?(host, &1)),
      do: {:ok, "#{protocol(dynamic, conn)}://#{host}"},
      else: fallback(dynamic)
  end

  @doc "Trusted origins implied by the base URL config."
  @spec trusted_origins(String.t() | keyword()) :: [String.t()]
  def trusted_origins(url) when is_binary(url), do: [url]

  def trusted_origins(dynamic) do
    protocols =
      case dynamic[:protocol] do
        :auto -> ["https", "http"]
        protocol -> [protocol]
      end

    origins =
      for host <- dynamic[:allowed_hosts], protocol <- protocols, do: "#{protocol}://#{host}"

    origins ++ List.wrap(dynamic[:fallback])
  end

  @doc "Raises on invalid config."
  @spec validate!(String.t() | keyword()) :: :ok
  def validate!(url) when is_binary(url), do: check_url!(url, "base_url")

  def validate!(dynamic) do
    if dynamic[:allowed_hosts] in [nil, []],
      do: raise(ArgumentError, "base_url: [allowed_hosts: ...] needs at least one host")

    if dynamic[:fallback], do: check_url!(dynamic[:fallback], "base_url fallback")
    :ok
  end

  defp check_url!(url, name) do
    if Origin.origin(url),
      do: :ok,
      else: raise(ArgumentError, "#{name} must be an http(s) URL, got: #{inspect(url)}")
  end

  defp fallback(dynamic) do
    case dynamic[:fallback] do
      nil -> {:error, Error.new(:invalid_host)}
      url -> {:ok, url}
    end
  end

  defp request_host(conn) do
    host = header(conn, "x-forwarded-host") || host_with_port(conn.host, conn.port)

    host = host |> String.split(",") |> hd() |> String.trim() |> String.downcase()
    if String.match?(host, @host_format), do: host
  end

  defp host_with_port(host, port) when port in [80, 443], do: host
  defp host_with_port(host, port), do: "#{host}:#{port}"

  defp host_matches?(host, pattern) do
    if String.contains?(pattern, "*"),
      do: Origin.glob_match?(pattern, host),
      else: host == String.downcase(pattern)
  end

  defp protocol(dynamic, conn) do
    case {dynamic[:protocol], header(conn, "x-forwarded-proto")} do
      {:auto, proto} when proto in ["http", "https"] -> proto
      {:auto, _missing} -> Atom.to_string(conn.scheme)
      {protocol, _} -> protocol
    end
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
end
