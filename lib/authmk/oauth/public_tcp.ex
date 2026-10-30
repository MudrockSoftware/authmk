defmodule Authmk.OAuth.PublicTCP do
  @moduledoc false
  # A `gen_tcp` callback module (`{:tcp_module, PublicTCP}`) that only
  # connects to public addresses. The host is resolved here and the socket
  # connects to the address that was checked, so a DNS answer that changes
  # between a check and the connection (DNS rebinding) can't reach a
  # private network. TLS still verifies the certificate for the host name.
  #
  # `Authmk.OAuth.HTTP.public_hosts_only/1` turns it on for a request.

  alias Authmk.OAuth.PublicHost

  # Every address must be public, as in `PublicHost.check/2`: a host that
  # also resolves to a private one isn't fetched at all.
  def getaddrs(address, timer) do
    case resolve(address, timer) do
      {:ok, [_ | _] = addresses} ->
        if Enum.all?(addresses, &PublicHost.public?/1),
          do: {:ok, addresses},
          else: {:error, :eaddrnotavail}

      _unresolved ->
        {:error, :nxdomain}
    end
  end

  def getserv(port), do: :inet_tcp.getserv(port)

  # Checked again here: `gen_tcp` skips `getaddrs/2` for literal addresses.
  def connect(address, port, opts, timeout) do
    cond do
      not PublicHost.public?(address) -> {:error, :eaddrnotavail}
      tuple_size(address) == 8 -> :inet6_tcp.connect(address, port, opts, timeout)
      true -> :inet_tcp.connect(address, port, opts, timeout)
    end
  end

  # IPv4 addresses, or IPv6 ones for hosts without any.
  defp resolve(address, timer) do
    case :inet_tcp.getaddrs(address, timer) do
      {:ok, [_ | _] = addresses} -> {:ok, addresses}
      _none -> :inet6_tcp.getaddrs(address, timer)
    end
  end
end
