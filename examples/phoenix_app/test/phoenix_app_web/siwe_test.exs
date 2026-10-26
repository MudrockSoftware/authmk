defmodule PhoenixAppWeb.SIWETest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing.FakeWallet

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "sign in with an Ethereum wallet", %{conn: conn} do
    wallet = FakeWallet.new()

    conn =
      conn
      |> from_browser()
      |> post("/auth/siwe/nonce", %{wallet_address: wallet.address, chain_id: 1})

    message =
      FakeWallet.message(wallet,
        domain: "localhost:4000",
        nonce: json_response(conn, 200)["nonce"]
      )

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/siwe/verify", %{
        message: message,
        signature: FakeWallet.sign(wallet, message),
        wallet_address: wallet.address,
        chain_id: 1
      })

    assert json_response(conn, 200)["success"] == true

    conn = conn |> recycle() |> get(~p"/account")
    assert html_response(conn, 200) =~ wallet.address
  end
end
