defmodule Authmk.OAuth.PublicHost do
  @moduledoc false
  # Before fetching a URL someone else chose: its host must resolve to
  # public addresses only, never loopback, private or link-local ones
  # (server-side request forgery). `resolve` replaces DNS, for tests or a
  # stricter policy.

  @doc "`:ok` when every address of `host` is public, else `:error`."
  def check(host, resolve \\ nil) when is_binary(host) do
    resolve = resolve || (&resolve/1)

    case resolve.(host) do
      {:ok, [_ | _] = addresses} -> if Enum.all?(addresses, &public?/1), do: :ok, else: :error
      _unresolved -> :error
    end
  end

  defp resolve(host) do
    host = String.to_charlist(host)

    case {:inet.getaddrs(host, :inet), :inet.getaddrs(host, :inet6)} do
      {{:ok, v4}, {:ok, v6}} -> {:ok, v4 ++ v6}
      {{:ok, v4}, _none} -> {:ok, v4}
      {_none, {:ok, v6}} -> {:ok, v6}
      _neither -> :error
    end
  end

  @doc "Whether an `:inet` address is public: not loopback, private, link-local or multicast."
  def public?(address)

  def public?({10, _, _, _}), do: false
  def public?({127, _, _, _}), do: false
  def public?({169, 254, _, _}), do: false
  def public?({172, second, _, _}) when second in 16..31, do: false
  def public?({192, 168, _, _}), do: false
  def public?({100, second, _, _}) when second in 64..127, do: false
  def public?({0, _, _, _}), do: false
  def public?({first, _, _, _}) when first >= 224, do: false
  def public?({0, 0, 0, 0, 0, 0, 0, _}), do: false
  def public?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  def public?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: false
  def public?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: false
  def public?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: false
  def public?(_address), do: true
end
