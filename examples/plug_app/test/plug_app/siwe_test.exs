defmodule PlugApp.SIWETest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing.FakeWallet

  test "sign in with an Ethereum wallet" do
    wallet = FakeWallet.new()
    conn = post_json("/auth/siwe/nonce", %{wallet_address: wallet.address, chain_id: 1})
    message = FakeWallet.message(wallet, domain: "localhost:4001", nonce: json(conn)["nonce"])

    conn =
      post_json("/auth/siwe/verify", %{
        message: message,
        signature: FakeWallet.sign(wallet, message),
        wallet_address: wallet.address,
        chain_id: 1
      })

    assert json(conn)["user"]["name"] == wallet.address
    assert get_path("/me", cookies(conn)).status == 200
  end
end
