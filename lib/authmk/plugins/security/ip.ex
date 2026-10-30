defmodule Authmk.Plugins.Security.IP do
  @moduledoc false
  # IP addresses and CIDR ranges.

  import Bitwise

  @doc ~s[Whether `address` (a tuple) is in any of `ranges`, like "10.0.0.0/8" or "2001:db8::/32".]
  def member?(nil, _ranges), do: false

  def member?(address, ranges), do: Enum.any?(ranges, &in_range?(address, &1))

  defp in_range?(address, range) do
    {network, bits} =
      case String.split(range, "/", parts: 2) do
        [network, bits] -> {network, String.to_integer(bits)}
        [network] -> {network, nil}
      end

    case :inet.parse_address(String.to_charlist(network)) do
      {:ok, network} when tuple_size(network) == tuple_size(address) ->
        size = if tuple_size(address) == 4, do: 32, else: 128
        bits = bits || size
        shift = size - bits
        to_integer(address) >>> shift == to_integer(network) >>> shift

      _other ->
        false
    end
  end

  defp to_integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp to_integer(v6) when tuple_size(v6) == 8,
    do: v6 |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
end
