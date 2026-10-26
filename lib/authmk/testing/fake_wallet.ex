defmodule Authmk.Testing.FakeWallet do
  @moduledoc """
  An Ethereum wallet for tests: signs Sign-In with Ethereum messages the way
  a wallet's `personal_sign` would. Needs `{:ex_secp256k1, "~> 0.8"}` and
  `{:ex_keccak, "~> 0.7"}`, like `Authmk.Plugins.SIWE`.

      wallet = Authmk.Testing.FakeWallet.new()
      message = FakeWallet.message(wallet, domain: "localhost:4000", nonce: nonce)
      signature = FakeWallet.sign(wallet, message)
  """

  @compile {:no_warn_undefined, [ExKeccak, ExSecp256k1]}

  alias Authmk.Plugins.SIWE.Ethereum

  defstruct [:private_key, :address]

  @type t :: %__MODULE__{}

  @doc "A wallet with a fresh key."
  @spec new() :: t()
  def new do
    private_key = :crypto.strong_rand_bytes(32)
    {:ok, <<4, public_key::binary-64>>} = ExSecp256k1.create_public_key(private_key)
    %__MODULE__{private_key: private_key, address: Ethereum.address(public_key)}
  end

  @doc """
  An EIP-4361 message from this wallet. Options: `:domain`, `:nonce`
  (required), `:chain_id` (1), `:uri`, `:statement`, `:issued_at`,
  `:expiration_time`, `:not_before`, `:request_id`, `:resources`, `:address`.
  """
  @spec message(t(), keyword()) :: String.t()
  def message(wallet, opts) do
    domain = Keyword.fetch!(opts, :domain)

    lines =
      [
        "#{domain} wants you to sign in with your Ethereum account:",
        Keyword.get(opts, :address, wallet.address),
        ""
      ] ++
        statement(opts[:statement]) ++
        [
          "URI: #{Keyword.get(opts, :uri, "https://#{domain}")}",
          "Version: 1",
          "Chain ID: #{Keyword.get(opts, :chain_id, 1)}",
          "Nonce: #{Keyword.fetch!(opts, :nonce)}",
          "Issued At: #{DateTime.to_iso8601(Keyword.get(opts, :issued_at, DateTime.utc_now()))}"
        ] ++
        time("Expiration Time", opts[:expiration_time]) ++
        time("Not Before", opts[:not_before]) ++
        if(opts[:request_id], do: ["Request ID: #{opts[:request_id]}"], else: []) ++
        resources(opts[:resources])

    Enum.join(lines, "\n")
  end

  @doc """
  A `personal_sign` signature of `message`, as 0x-prefixed hex. Its last
  byte is 27 or 28; `v_offset: 0` gives 0 or 1, like some hardware wallets.
  """
  @spec sign(t(), String.t(), keyword()) :: String.t()
  def sign(wallet, message, opts \\ []) do
    hash = ExKeccak.hash_256("\x19Ethereum Signed Message:\n#{byte_size(message)}" <> message)
    {:ok, {signature, recovery_id}} = ExSecp256k1.sign_compact(hash, wallet.private_key)
    v = Keyword.get(opts, :v_offset, 27) + recovery_id
    "0x" <> Base.encode16(signature <> <<v>>, case: :lower)
  end

  defp statement(nil), do: []
  defp statement(statement), do: [statement, ""]

  defp resources(nil), do: []
  defp resources(uris), do: ["Resources:" | Enum.map(uris, &("- " <> &1))]

  defp time(_label, nil), do: []
  defp time(label, time), do: ["#{label}: #{DateTime.to_iso8601(time)}"]
end
