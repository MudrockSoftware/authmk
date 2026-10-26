defmodule PlugApp.PasskeyTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing.FakeAuthenticator

  test "register a passkey, then sign in with it" do
    authenticator = FakeAuthenticator.new(origin: "http://localhost:4001")
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
    session = cookies(post_json("/auth/sign-up/email", user))

    conn = post_json("/auth/passkey/generate-register-options", %{}, session)
    response = FakeAuthenticator.register(authenticator, json(conn))
    session = Map.merge(session, cookies(conn))

    conn =
      post_json(
        "/auth/passkey/verify-registration",
        %{response: response, name: "Laptop"},
        session
      )

    assert json(conn)["passkey"]["name"] == "Laptop"

    post_json("/auth/sign-out", %{}, session)

    conn = post_json("/auth/passkey/generate-authenticate-options", %{})
    challenge = cookies(conn)
    {_authenticator, response} = FakeAuthenticator.authenticate(authenticator, json(conn))
    conn = post_json("/auth/passkey/verify-authentication", %{response: response}, challenge)
    assert get_path("/me", cookies(conn)).status == 200
  end
end
