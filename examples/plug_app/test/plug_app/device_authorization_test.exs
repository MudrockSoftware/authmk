defmodule PlugApp.DeviceAuthorizationTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  @grant "urn:ietf:params:oauth:grant-type:device_code"

  test "a TV signs in, approved by a signed-in user" do
    # With the OAuth provider, device apps are registered clients (once, in
    # seeds or a release task). Unknown ones get no codes.
    assert json(post_json("/auth/device/code", %{client_id: "tv-device"}))["error"] ==
             "invalid_client"

    {:ok, _tv} =
      Authmk.Plugins.OAuthProvider.create_client(
        PlugApp.Auth,
        %{"grant_types" => [@grant], "token_endpoint_auth_method" => "none"},
        client_id: "tv-device"
      )

    codes = json(post_json("/auth/device/code", %{client_id: "tv-device"}))

    phone =
      cookies(
        post_json("/auth/sign-up/email", %{
          email: "ada@example.com",
          password: "correct horse",
          name: "Ada"
        })
      )

    post_json("/auth/device/approve", %{user_code: codes["user_code"]}, phone)

    token =
      json(
        post_json("/auth/device/token", %{
          grant_type: @grant,
          device_code: codes["device_code"],
          client_id: "tv-device"
        })
      )

    conn =
      Plug.Test.conn(:get, "/me")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token["access_token"])
      |> call()

    assert json(conn)["email"] == "ada@example.com"
  end
end
