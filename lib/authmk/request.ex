defmodule Authmk.Request do
  @moduledoc false
  # Facts about the incoming request: client IP and user agent.

  alias Authmk.Context
  alias Authmk.OAuth.PublicHost

  @doc """
  The client IP as a string, or `nil`. Proxy headers are only read when
  configured in `advanced: [ip_address_headers: [...]]`, since clients can set
  them freely.
  """
  @spec client_ip(Context.t()) :: String.t() | nil
  def client_ip(ctx) do
    case client_address(ctx) do
      nil -> nil
      address -> address |> :inet.ntoa() |> to_string()
    end
  end

  @doc "The client IP as an `:inet` address tuple, or `nil`."
  @spec client_address(Context.t()) :: :inet.ip_address() | nil
  def client_address(%Context{conn: nil}), do: nil

  def client_address(%Context{conn: conn, config: config}) do
    Enum.find_value(config.advanced[:ip_address_headers], conn.remote_ip, &header_ip(conn, &1))
  end

  @doc "The User-Agent header, or `nil`."
  @spec user_agent(Context.t()) :: String.t() | nil
  def user_agent(%Context{conn: nil}), do: nil

  def user_agent(%Context{conn: conn}) do
    conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
  end

  # Proxies append to headers like X-Forwarded-For, so only the right end is
  # trustworthy: the left end is whatever the client sent. Walking from the
  # right, the first public address is the client's; the private ones before
  # it are your own proxies. With only private addresses, the rightmost wins.
  defp header_ip(conn, header) do
    addresses =
      conn
      |> Plug.Conn.get_req_header(header)
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.flat_map(&parse_address/1)
      |> Enum.reverse()

    Enum.find(addresses, List.first(addresses), &PublicHost.public?/1)
  end

  defp parse_address(value) do
    case :inet.parse_address(value |> String.trim() |> String.to_charlist()) do
      {:ok, ip} -> [ip]
      {:error, _invalid} -> []
    end
  end
end
