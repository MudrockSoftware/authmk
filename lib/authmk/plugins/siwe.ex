defmodule Authmk.Plugins.SIWE do
  @moduledoc """
  Sign-In with Ethereum (EIP-4361): wallets sign a message, and the
  signature is the credential.

      # mix.exs
      {:ex_secp256k1, "~> 0.8"},
      {:ex_keccak, "~> 0.7"}

      use Authmk,
        plugins: [{Authmk.Plugins.SIWE, domain: "app.example.com"}],
        ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/siwe/nonce` | none |
  | POST | `/siwe/verify` | none |

  1. `POST /siwe/nonce` with `wallet_address` and `chain_id` (default 1)
     returns a `nonce`.
  2. The client builds the EIP-4361 message with it (domain, checksummed
     address, chain id, nonce), and the wallet signs it with `personal_sign`.
  3. `POST /siwe/verify` with `message`, `signature`, `wallet_address` and
     `chain_id` signs in.

  The signed message decides who signs in: its address must have signed it,
  and match `wallet_address`; its domain must be `domain`, its chain the
  requested one, its nonce the one just issued (each works once), and it
  must not be expired or not yet valid. Users have wallet addresses per
  chain; the same address on another chain signs in the same user. Wallets
  never join an account by email: owning a wallet doesn't prove owning an
  email.

  New users are named after their ENS name (with `ens_lookup`) or their
  address.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.SIWE.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Context,
    Email,
    Endpoint,
    Error,
    Serializer,
    Sessions,
    Store,
    Verification
  }

  alias Authmk.Plugins.SIWE.{Ethereum, Message, Options}

  @purpose "siwe"
  # Clocks differ a little between wallets and servers.
  @clock_skew 60

  @impl true
  def init(opts) do
    unless Code.ensure_loaded?(ExSecp256k1) and Code.ensure_loaded?(ExKeccak) do
      raise ArgumentError,
            ~s(Authmk.Plugins.SIWE needs {:ex_secp256k1, "~> 0.8"} and {:ex_keccak, "~> 0.7"} in your deps)
    end

    NimbleOptions.validate!(opts, Options.schema())
  end

  @impl true
  def schema(_opts) do
    %{
      wallet_address: [
        plural: "wallet_addresses",
        fields: [
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          # EIP-55 checksummed.
          address: [type: :string, required: true, input: false],
          chain_id: [type: :integer, required: true, input: false],
          is_primary: [type: :boolean, required: true, default: false, input: false]
        ],
        indexes: [[columns: [:address, :chain_id], unique: true]]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    wallet = [
      wallet_address: [type: :string, required: true],
      chain_id: [type: :integer, default: 1]
    ]

    [
      Endpoint.new(
        name: :siwe_nonce,
        method: :post,
        path: "/siwe/nonce",
        handler: {__MODULE__, :nonce},
        rate_limit: [window: 60, max: 10],
        params: wallet
      ),
      Endpoint.new(
        name: :siwe_verify,
        method: :post,
        path: "/siwe/verify",
        handler: {__MODULE__, :verify},
        rate_limit: [window: 60, max: 10],
        params:
          wallet ++
            [
              message: [type: :string, required: true],
              signature: [type: :string, required: true],
              email: [type: :string]
            ]
      )
    ]
  end

  @doc false
  def nonce(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with {:ok, address} <- address(params.wallet_address) do
      nonce = nonce_string()
      key = nonce_key(address, params.chain_id)
      :ok = Verification.delete(ctx, @purpose, key)

      with {:ok, _key} <-
             Verification.create(ctx, @purpose, %{"nonce" => nonce}, opts[:nonce_expires_in], key) do
        {:ok, %{nonce: nonce}, ctx}
      end
    end
  end

  @doc false
  def verify(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with {:ok, message} <- parse(params.message),
         :ok <- check_message(ctx, message, opts),
         :ok <- check(Ethereum.checksummed?(message.address), invalid_message()),
         {:ok, address} <- address(params.wallet_address),
         :ok <-
           check(
             address == message.address and params.chain_id == message.chain_id,
             invalid_message()
           ),
         :ok <- use_nonce(ctx, message),
         {:ok, signer} <- signer(params),
         :ok <- check(signer == message.address, invalid_signature()),
         {:ok, user} <- find_or_sign_up(ctx, message, opts) do
      case Sessions.sign_in(ctx, user) do
        {:ok, ctx} -> {:ok, %{success: true, user: Serializer.user(ctx, user)}, ctx}
        {:challenge, body, ctx} -> {:ok, body, ctx}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp parse(message) do
    case Message.parse(message) do
      {:ok, message} -> {:ok, message}
      :error -> {:error, invalid_message()}
    end
  end

  # The domain and the times. No side effects, so it comes before the nonce.
  defp check_message(ctx, message, opts) do
    now = DateTime.utc_now()

    checks = [
      message.domain == domain(ctx, opts),
      DateTime.diff(message.issued_at, now) <= @clock_skew,
      is_nil(message.expiration_time) or DateTime.after?(message.expiration_time, now),
      is_nil(message.not_before) or DateTime.diff(message.not_before, now) <= @clock_skew
    ]

    check(Enum.all?(checks), invalid_message())
  end

  # Used up whether or not the rest checks out.
  defp use_nonce(ctx, message) do
    key = nonce_key(message.address, message.chain_id)

    case Verification.consume(ctx, @purpose, key) do
      {:ok, %{"nonce" => nonce}} ->
        check(Plug.Crypto.secure_compare(nonce, message.nonce), invalid_nonce())

      {:error, _not_found} ->
        {:error, invalid_nonce()}
    end
  end

  defp signer(%{message: raw, signature: signature}) do
    case Ethereum.recover_address(raw, signature) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, invalid_signature()}
    end
  end

  # The wallet on this chain, the same address on another chain, or a new user.
  defp find_or_sign_up(ctx, %{address: address, chain_id: chain_id}, opts) do
    case Store.get_by(ctx, :wallet_address, address: address, chain_id: chain_id) do
      %{user_id: user_id} ->
        {:ok, Store.get_by(ctx, :user, id: user_id)}

      nil ->
        case Store.all(ctx, :wallet_address, [address: address], limit: 1) do
          [%{user_id: user_id}] ->
            add_wallet(ctx, Store.get_by(ctx, :user, id: user_id), address, chain_id, false)

          [] ->
            sign_up(ctx, address, chain_id, opts)
        end
    end
  end

  defp sign_up(%Context{params: params} = ctx, address, chain_id, opts) do
    ens = if opts[:ens_lookup], do: opts[:ens_lookup].(address)

    with {:ok, email} <- new_user_email(ctx, address, params.email, opts) do
      attrs = %{email: email, name: (ens && ens[:name]) || address, image: ens && ens[:avatar]}
      create_user_with_wallet(ctx, attrs, address, chain_id)
    end
  end

  defp create_user_with_wallet(ctx, attrs, address, chain_id) do
    Store.transaction(ctx, fn ->
      with {:ok, user} <- Store.insert(ctx, :user, attrs) do
        add_wallet(ctx, user, address, chain_id, true)
      end
    end)
  end

  defp add_wallet(ctx, user, address, chain_id, primary) do
    attrs = %{user_id: user.id, address: address, chain_id: chain_id, is_primary: primary}

    with {:ok, _wallet} <- Store.insert(ctx, :wallet_address, attrs) do
      {:ok, user}
    end
  end

  defp new_user_email(ctx, address, email, opts) do
    cond do
      opts[:anonymous] ->
        {:ok, placeholder(ctx, address, opts)}

      is_nil(email) ->
        {:error, Error.custom(:email_required, 400, "An email is needed to sign up")}

      not Email.valid?(Email.normalize(email)) ->
        {:error, Error.new(:invalid_email)}

      Store.get_by(ctx, :user, email: Email.normalize(email)) ->
        {:error, Error.new(:user_already_exists)}

      true ->
        {:ok, Email.normalize(email)}
    end
  end

  defp placeholder(ctx, address, opts),
    do: String.downcase(address) <> "@" <> (opts[:email_domain] || domain(ctx, opts))

  defp domain(%Context{base_url: base_url}, opts) do
    case opts[:domain] do
      nil ->
        uri = URI.parse(base_url)
        if uri.port in [80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"

      domain ->
        domain
    end
  end

  defp address(address) do
    case Ethereum.checksum(address) do
      :error ->
        {:error, Error.custom(:invalid_wallet_address, 400, "This isn't an Ethereum address")}

      checksummed ->
        {:ok, checksummed}
    end
  end

  defp nonce_key(address, chain_id), do: "#{String.downcase(address)}:#{chain_id}"

  # 128 random bits in base 36: alphanumeric, as EIP-4361 asks.
  defp nonce_string do
    :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned() |> Integer.to_string(36)
  end

  defp invalid_message,
    do: Error.custom(:invalid_siwe_message, 400, "The sign-in message isn't valid")

  defp invalid_signature,
    do: Error.custom(:invalid_siwe_signature, 401, "The signature doesn't match")

  defp invalid_nonce,
    do: Error.custom(:invalid_siwe_nonce, 401, "Ask for a new nonce and sign again")

  defp check(true, _error), do: :ok
  defp check(_false, error), do: {:error, error}
end
