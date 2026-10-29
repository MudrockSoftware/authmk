defmodule PlugApp.JWTTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "a JWT for the session, checked with the published keys" do
    session =
      cookies(
        post_json("/auth/sign-up/email", %{
          email: "ada@example.com",
          password: "correct horse",
          name: "Ada"
        })
      )

    token = json(get_path("/auth/token", session))["token"]

    assert {:ok, %{"email" => "ada@example.com"}} = Authmk.Plugins.JWT.verify(PlugApp.Auth, token)
    assert [%{"alg" => "EdDSA"}] = json(get_path("/auth/jwks"))["keys"]
  end
end
