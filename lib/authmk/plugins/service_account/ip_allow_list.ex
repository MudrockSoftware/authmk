defmodule Authmk.Plugins.ServiceAccount.IPAllowList do
  @moduledoc false
  # Addresses and CIDR ranges (IPv4 and IPv6), like "10.0.0.0/8" or
  # "2001:db8::/32".

  import Bitwise

  @doc "Whether every entry is an address or a range."
  def valid?(entries), do: Enum.all?(entries, &match?({:ok, _range}, parse(&1)))

  @doc "Whether `ip` (a string) is in one of the entries."
  def allowed?(ip, entries) when is_binary(ip) do
    case :inet.parse_address(to_charlist(ip)) do
      {:ok, address} -> Enum.any?(entries, &in_range?(address, &1))
      {:error, _invalid} -> false
    end
  end

  def allowed?(_ip, _entries), do: false

  defp in_range?(address, entry) do
    case parse(entry) do
      {:ok, {network, bits}} ->
        same_family?(address, network) and prefix(address, bits) == prefix(network, bits)

      :error ->
        false
    end
  end

  defp parse(entry) do
    {host, bits} =
      case String.split(entry, "/", parts: 2) do
        [host, bits] -> {host, Integer.parse(bits)}
        [host] -> {host, nil}
      end

    with {:ok, network} <- :inet.parse_address(to_charlist(host)),
         {:ok, bits} <- prefix_length(network, bits) do
      {:ok, {network, bits}}
    else
      _invalid -> :error
    end
  end

  defp prefix_length(network, nil), do: {:ok, size(network)}

  defp prefix_length(network, {bits, ""}) when bits >= 0,
    do: if(bits <= size(network), do: {:ok, bits}, else: :error)

  defp prefix_length(_network, _bits), do: :error

  defp size(address) when tuple_size(address) == 4, do: 32
  defp size(address) when tuple_size(address) == 8, do: 128

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp prefix(address, bits) do
    {integer, size} = to_integer(address)
    integer >>> (size - bits)
  end

  defp to_integer({a, b, c, d}), do: {(a <<< 24) + (b <<< 16) + (c <<< 8) + d, 32}

  defp to_integer(address) do
    integer =
      address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)

    {integer, 128}
  end
end
