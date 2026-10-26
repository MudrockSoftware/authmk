defmodule Authmk.Plugins.SIWE.Ethereum do
  @moduledoc false
  # Ethereum addresses and personal_sign signatures (EIP-191, EIP-55).
  #
  # ex_secp256k1 and ex_keccak are optional dependencies: this module
  # compiles without them, and the plugin refuses to start when they're missing.
  @compile {:no_warn_undefined, [ExKeccak, ExSecp256k1]}

  @doc "The address that signed `message` with personal_sign, or `:error`."
  def recover_address(message, "0x" <> signature_hex) do
    with {:ok, <<r::binary-32, s::binary-32, v>>} <- Base.decode16(signature_hex, case: :mixed),
         {:ok, recovery_id} <- recovery_id(v),
         {:ok, <<4, public_key::binary-64>>} <-
           ExSecp256k1.recover_compact(personal_hash(message), r <> s, recovery_id) do
      {:ok, address(public_key)}
    else
      _invalid -> :error
    end
  end

  def recover_address(_message, _signature), do: :error

  @doc "The checksummed (EIP-55) address of a 64-byte public key."
  def address(public_key) do
    <<_::binary-12, address::binary-20>> = ExKeccak.hash_256(public_key)
    checksum("0x" <> Base.encode16(address, case: :lower))
  end

  @doc "The address with EIP-55 mixed-case checksum, or `:error` when it isn't an address."
  def checksum("0x" <> hex) when byte_size(hex) == 40 do
    lower = String.downcase(hex)
    if lower =~ ~r/^[0-9a-f]{40}$/, do: "0x" <> mixed_case(lower), else: :error
  end

  def checksum(_not_an_address), do: :error

  # A letter is uppercase where the Keccak hash of the lowercase address has
  # a nibble of 8 or more.
  defp mixed_case(lower) do
    hash = lower |> ExKeccak.hash_256() |> Base.encode16(case: :lower)

    lower
    |> String.graphemes()
    |> Enum.zip(String.graphemes(hash))
    |> Enum.map_join(fn {char, nibble} ->
      if nibble >= "8", do: String.upcase(char), else: char
    end)
  end

  @doc "Whether `address` carries a correct EIP-55 checksum."
  def checksummed?(address), do: checksum(address) == address

  # "\x19Ethereum Signed Message:\n" <> length <> message, hashed with Keccak-256.
  defp personal_hash(message),
    do: ExKeccak.hash_256("\x19Ethereum Signed Message:\n#{byte_size(message)}" <> message)

  defp recovery_id(v) when v in [0, 1], do: {:ok, v}
  defp recovery_id(v) when v in [27, 28], do: {:ok, v - 27}
  defp recovery_id(_v), do: :error
end
