defmodule Authmk.SIWETest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.Repo
  alias Authmk.Testing.FakeWallet

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, skip_verification_on_enable: true, allow_passwordless: true},
        {Authmk.Plugins.SIWE, ens_lookup: &__MODULE__.ens/1}
      ]

    # One wallet has an ENS name.
    def ens(address) do
      if Process.get(:ens_address) == address,
        do: %{name: "ada.eth", avatar: "https://ens.example/ada.png"}
    end
  end

  @moduletag auth: Auth

  @domain "localhost:4000"

  defp get_nonce(browser, wallet, chain_id \\ 1) do
    {browser, conn} =
      post(browser, "/siwe/nonce", %{wallet_address: wallet.address, chain_id: chain_id})

    {browser, json(conn)["nonce"]}
  end

  # The whole flow, with `message_opts` changing the signed message.
  defp sign_in(browser, wallet, message_opts \\ [], chain_id \\ 1) do
    {browser, nonce} = get_nonce(browser, wallet, chain_id)

    message =
      FakeWallet.message(
        wallet,
        Keyword.merge([domain: @domain, nonce: nonce, chain_id: chain_id], message_opts)
      )

    post(browser, "/siwe/verify", %{
      message: message,
      signature: FakeWallet.sign(wallet, message),
      wallet_address: wallet.address,
      chain_id: chain_id
    })
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  test "a wallet signs up, then signs in again", %{browser: browser} do
    wallet = FakeWallet.new()

    {browser, conn} = sign_in(browser, wallet, statement: "Sign in to Acme")
    user = json(conn)["user"]
    assert user["name"] == wallet.address
    assert user["email"] == String.downcase(wallet.address) <> "@localhost:4000"
    assert signed_in_user(browser)["id"] == user["id"]

    {browser, _conn} = post(browser, "/sign-out")
    {_browser, conn} = sign_in(browser, wallet)
    assert json(conn)["user"]["id"] == user["id"]
    assert Repo.aggregate("users", :count) == 1
  end

  test "every optional field, and hardware wallets' 0/1 signatures", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, nonce} = get_nonce(browser, wallet)

    message =
      FakeWallet.message(wallet,
        domain: @domain,
        nonce: nonce,
        statement: "Sign in to Acme",
        expiration_time: DateTime.add(DateTime.utc_now(), 300),
        not_before: DateTime.add(DateTime.utc_now(), -10),
        request_id: "req-1",
        resources: ["ipfs://bafy", "https://example.com/terms"]
      )

    {_browser, conn} =
      post(browser, "/siwe/verify", %{
        message: message,
        signature: FakeWallet.sign(wallet, message, v_offset: 0),
        wallet_address: wallet.address,
        chain_id: 1
      })

    assert json(conn)["success"] == true
  end

  test "messages that bend the format are refused", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, nonce} = get_nonce(browser, wallet)
    good = FakeWallet.message(wallet, domain: @domain, nonce: nonce)

    for bad <- [
          String.replace(good, "Version: 1", "Version: 2"),
          String.replace(good, "Chain ID: 1", "Chain ID: one"),
          String.replace(good, "Nonce: " <> nonce, "Nonce: short"),
          good <> "\nExpiration Time: soon",
          good <> "\nResources:\nnot a list item",
          good <> "\nSomething: else",
          String.replace(good, " wants you to sign in", " would like you to sign in")
        ] do
      {_browser, conn} =
        post(browser, "/siwe/verify", %{
          message: bad,
          signature: FakeWallet.sign(wallet, bad),
          wallet_address: wallet.address,
          chain_id: 1
        })

      assert json(conn)["error"]["code"] == "invalid_siwe_message"
    end
  end

  test "the same address on another chain is the same user", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, conn} = sign_in(browser, wallet)
    id = json(conn)["user"]["id"]
    {browser, _conn} = post(browser, "/sign-out")

    {_browser, conn} = sign_in(browser, wallet, [], 137)
    assert json(conn)["user"]["id"] == id

    assert Enum.sort(Repo.all(from(w in "wallet_addresses", select: w.chain_id))) == [1, 137]
  end

  test "ENS names and avatars name new users", %{browser: browser} do
    wallet = FakeWallet.new()
    Process.put(:ens_address, wallet.address)

    {_browser, conn} = sign_in(browser, wallet)
    assert json(conn)["user"]["name"] == "ada.eth"
    assert json(conn)["user"]["image"] == "https://ens.example/ada.png"
  end

  test "messages for another domain, chain or address, or out of time, are refused", %{
    browser: browser
  } do
    wallet = FakeWallet.new()
    other = FakeWallet.new()
    hour = 3600

    for opts <- [
          [domain: "evil.example"],
          [chain_id: 5],
          [address: other.address],
          [address: String.downcase(wallet.address)],
          [expiration_time: DateTime.add(DateTime.utc_now(), -hour)],
          [not_before: DateTime.add(DateTime.utc_now(), hour)],
          [issued_at: DateTime.add(DateTime.utc_now(), hour)]
        ] do
      {_browser, conn} = sign_in(browser, wallet, opts)
      assert json(conn)["error"]["code"] == "invalid_siwe_message", inspect(opts)
    end

    assert Repo.aggregate("users", :count) == 0
  end

  test "someone else's signature is refused", %{browser: browser} do
    wallet = FakeWallet.new()
    thief = FakeWallet.new()
    {browser, nonce} = get_nonce(browser, wallet)
    message = FakeWallet.message(wallet, domain: @domain, nonce: nonce)

    {_browser, conn} =
      post(browser, "/siwe/verify", %{
        message: message,
        signature: FakeWallet.sign(thief, message),
        wallet_address: wallet.address,
        chain_id: 1
      })

    assert json(conn)["error"]["code"] == "invalid_siwe_signature"
    assert signed_in_user(browser) == nil
  end

  test "a signature for another message is refused", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, nonce} = get_nonce(browser, wallet)
    message = FakeWallet.message(wallet, domain: @domain, nonce: nonce)

    other_message =
      FakeWallet.message(wallet, domain: @domain, nonce: nonce, statement: "Something else")

    {_browser, conn} =
      post(browser, "/siwe/verify", %{
        message: message,
        signature: FakeWallet.sign(wallet, other_message),
        wallet_address: wallet.address,
        chain_id: 1
      })

    assert json(conn)["error"]["code"] == "invalid_siwe_signature"
  end

  test "a nonce works once, and only the latest one", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, first} = get_nonce(browser, wallet)
    {browser, second} = get_nonce(browser, wallet)

    stale = FakeWallet.message(wallet, domain: @domain, nonce: first)

    signed = %{
      message: stale,
      signature: FakeWallet.sign(wallet, stale),
      wallet_address: wallet.address,
      chain_id: 1
    }

    {browser, conn} = post(browser, "/siwe/verify", signed)
    assert json(conn)["error"]["code"] == "invalid_siwe_nonce"

    # The failed attempt used up the latest nonce too.
    fresh = FakeWallet.message(wallet, domain: @domain, nonce: second)

    signed = %{
      message: fresh,
      signature: FakeWallet.sign(wallet, fresh),
      wallet_address: wallet.address,
      chain_id: 1
    }

    {_browser, conn} = post(browser, "/siwe/verify", signed)
    assert json(conn)["error"]["code"] == "invalid_siwe_nonce"
  end

  test "a signed message can't be replayed", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, nonce} = get_nonce(browser, wallet)
    message = FakeWallet.message(wallet, domain: @domain, nonce: nonce)

    signed = %{
      message: message,
      signature: FakeWallet.sign(wallet, message),
      wallet_address: wallet.address,
      chain_id: 1
    }

    {browser, _conn} = post(browser, "/siwe/verify", signed)
    {browser, _conn} = post(browser, "/sign-out")
    {_browser, conn} = post(browser, "/siwe/verify", signed)
    assert json(conn)["error"]["code"] == "invalid_siwe_nonce"
  end

  test "malformed input is refused", %{browser: browser} do
    {_browser, conn} = post(browser, "/siwe/nonce", %{wallet_address: "0x1234"})
    assert json(conn)["error"]["code"] == "invalid_wallet_address"

    wallet = FakeWallet.new()

    for {message, signature} <- [{"hello", "0x00"}, {"", ""}, {nil_message(wallet), "not hex"}] do
      {_browser, conn} =
        post(browser, "/siwe/verify", %{
          message: message,
          signature: signature,
          wallet_address: wallet.address
        })

      assert conn.status in [400, 401, 422]
    end
  end

  test "two-factor authentication applies", %{browser: browser} do
    wallet = FakeWallet.new()
    {browser, _conn} = sign_in(browser, wallet)
    {browser, _conn} = post(browser, "/two-factor/enable")
    {browser, _conn} = post(browser, "/sign-out")

    {browser, conn} = sign_in(browser, wallet)
    assert json(conn)["two_factor_redirect"] == true
    assert signed_in_user(browser) == nil
  end

  # A well-formed message whose signature is garbage.
  defp nil_message(wallet), do: FakeWallet.message(wallet, domain: @domain, nonce: "abcdefgh123")
end

defmodule Authmk.SIWEEmailTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Browser
  alias Authmk.Testing.FakeWallet

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.SIWE, anonymous: false, domain: "app.example.com"}
      ]
  end

  @moduletag auth: Auth

  defp verify(browser, wallet, extra) do
    {browser, conn} = post(browser, "/siwe/nonce", %{wallet_address: wallet.address})
    message = FakeWallet.message(wallet, domain: "app.example.com", nonce: json(conn)["nonce"])

    params = %{
      message: message,
      signature: FakeWallet.sign(wallet, message),
      wallet_address: wallet.address
    }

    post(browser, "/siwe/verify", Map.merge(params, extra))
  end

  test "new wallets need an email, and can't take someone's", %{browser: browser} do
    wallet = FakeWallet.new()

    {_browser, conn} = verify(browser, wallet, %{})
    assert json(conn)["error"]["code"] == "email_required"

    {_other, _user} = sign_up(Browser.new(Auth))
    {_browser, conn} = verify(browser, wallet, %{email: "ada@example.com"})
    assert json(conn)["error"]["code"] == "user_already_exists"

    {_browser, conn} = verify(browser, wallet, %{email: "Grace@Example.com"})
    assert json(conn)["user"]["email"] == "grace@example.com"
  end
end
