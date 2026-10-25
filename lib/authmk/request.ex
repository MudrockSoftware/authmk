defmodule Authmk.Request do
  @moduledoc false
  # Facts about the incoming request: client IP and user agent.

  alias Authmk.Context

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

  defp header_ip(conn, header) do
    with [value | _] <- Plug.Conn.get_req_header(conn, header),
         first = value |> String.split(",") |> hd() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(first)) do
      ip
    else
      _ -> nil
    end
  end
end
