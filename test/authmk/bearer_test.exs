defmodule Authmk.BearerTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query
  import Plug.Conn, only: [get_resp_header: 2]

  alias Authmk.Plug.FetchSession
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Bearer]
  end

  defmodule RawAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.Bearer, require_signature: false}]
  end

  @moduletag auth: Auth

  # A client that keeps no cookies, only the token.
  defp client(auth, token),
    do: %{Browser.new(auth) | headers: [{"authorization", "Bearer " <> token}]}

  # Signs up, then signs in and takes the token from the header.
  defp sign_in_token(auth) do
    {_browser, _user} = sign_up(Browser.new(auth))

    {_client, conn} =
      post(Browser.new(auth), "/sign-in/email", %{
        email: "ada@example.com",
        password: "correct horse"
      })

    assert get_resp_header(conn, "access-control-expose-headers") == ["set-auth-token"]
    [token] = get_resp_header(conn, "set-auth-token")
    token
  end

  test "the token from sign-in works without cookies, and refreshes come back", %{
    browser: _browser
  } do
    token = sign_in_token(Auth)

    {_client, conn} = get(client(Auth, token), "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
    assert get_resp_header(conn, "set-auth-token") == []

    # A refresh comes due; its response carries the token again.
    Repo.update_all(from(s in "sessions"),
      set: [expires_at: DateTime.add(DateTime.utc_now(), 60)]
    )

    {_client, conn} = get(client(Auth, token), "/get-session")
    assert get_resp_header(conn, "set-auth-token") == [token]

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> FetchSession.call(FetchSession.init(auth: Auth))

    assert conn.assigns.current_user.email == "ada@example.com"
  end

  test "forged and bare tokens are refused", %{browser: _browser} do
    token = sign_in_token(Auth)
    {:ok, bare} = Authmk.Crypto.verify(Auth.config(), "session-token", token)

    for bad <- ["v1.forged", token <> "x", bare] do
      {_client, conn} = get(client(Auth, bad), "/get-session")
      assert conn.status == 401, bad
    end
  end

  test "signing out ends the token", %{browser: _browser} do
    token = sign_in_token(Auth)
    {_client, _conn} = post(client(Auth, token), "/sign-out")
    {_client, conn} = get(client(Auth, token), "/get-session")
    assert json(conn) == nil
  end

  @tag auth: RawAuth
  test "bare session tokens, when signatures aren't required", %{browser: _browser} do
    token = sign_in_token(RawAuth)
    {:ok, bare} = Authmk.Crypto.verify(RawAuth.config(), "session-token", token)

    {_client, conn} = get(client(RawAuth, bare), "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
  end
end
