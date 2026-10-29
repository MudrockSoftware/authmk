defmodule Authmk.DeviceAuthorizationTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.{DeviceAuthorization, JWT}
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Bearer,
        {Authmk.Plugins.DeviceAuthorization, validate_client: &__MODULE__.client?/1}
      ]

    def client?(client_id), do: client_id == "tv-app"
  end

  defmodule JWTAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.DeviceAuthorization, token_type: :jwt}
      ]
  end

  @moduletag auth: Auth

  @grant "urn:ietf:params:oauth:grant-type:device_code"

  # The device: no cookies, no Origin.
  defp device(auth \\ Auth), do: %{Browser.new(auth) | origin: nil}

  defp request_codes(auth \\ Auth) do
    {_device, conn} = post(device(auth), "/device/code", %{client_id: "tv-app", scope: "watch"})
    json(conn)
  end

  defp poll(device_code, client_id \\ "tv-app", auth \\ Auth) do
    {_device, conn} =
      post(device(auth), "/device/token", %{
        grant_type: @grant,
        device_code: device_code,
        client_id: client_id
      })

    {conn.status, json(conn)}
  end

  # As if the device waited its interval.
  defp wait_interval,
    do:
      Repo.update_all(from(d in "device_codes"),
        set: [last_polled_at: DateTime.add(DateTime.utc_now(), -60)]
      )

  defp signed_in(email \\ "ada@example.com") do
    {browser, _user} = sign_up(Browser.new(Auth), %{email: email})
    browser
  end

  test "a TV signs in, approved from a phone", %{browser: _browser} do
    codes = request_codes()
    assert codes["user_code"] =~ ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/
    assert codes["verification_uri"] == "http://localhost:4000/device"

    assert codes["verification_uri_complete"] ==
             "http://localhost:4000/device?user_code=" <> codes["user_code"]

    assert codes["interval"] == 5

    assert poll(codes["device_code"]) == {400, %{"error" => "authorization_pending"}}
    # Too soon.
    assert poll(codes["device_code"]) == {400, %{"error" => "slow_down"}}
    assert [10] = Repo.all(from(d in "device_codes", select: d.polling_interval))

    phone = signed_in()
    typed = codes["user_code"] |> String.downcase() |> String.replace("-", " ")
    {phone, conn} = get(phone, "/device", %{user_code: typed})
    assert json(conn)["client_id"] == "tv-app"
    assert json(conn)["scope"] == "watch"
    {_phone, conn} = post(phone, "/device/approve", %{user_code: typed})
    assert json(conn) == %{"success" => true}

    wait_interval()
    {200, token} = poll(codes["device_code"])
    assert token["token_type"] == "Bearer"
    assert token["scope"] == "watch"

    tv = %{device() | headers: [{"authorization", "Bearer " <> token["access_token"]}]}
    {_tv, conn} = get(tv, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # The device code worked once.
    assert poll(codes["device_code"]) == {400, %{"error" => "invalid_grant"}}
  end

  test "denied, expired, and unknown codes", %{browser: _browser} do
    codes = request_codes()
    {_phone, _conn} = post(signed_in(), "/device/deny", %{user_code: codes["user_code"]})
    wait_interval()
    assert poll(codes["device_code"]) == {400, %{"error" => "access_denied"}}

    codes = request_codes()

    Repo.update_all(from(d in "device_codes"),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert poll(codes["device_code"]) == {400, %{"error" => "expired_token"}}

    {_phone, conn} =
      get(signed_in("grace@example.com"), "/device", %{user_code: codes["user_code"]})

    assert json(conn)["error"]["code"] == "expired_user_code"

    assert poll("made-up") == {400, %{"error" => "invalid_grant"}}

    {_phone, conn} =
      post(signed_in("alan@example.com"), "/device/approve", %{user_code: "BCDF-GHJK"})

    assert json(conn)["error"]["code"] == "invalid_user_code"
  end

  test "clients and grants are checked", %{browser: _browser} do
    {_device, conn} = post(device(), "/device/code", %{client_id: "evil-app"})
    assert {conn.status, json(conn)} == {400, %{"error" => "invalid_client"}}

    codes = request_codes()
    assert poll(codes["device_code"], "evil-app") == {400, %{"error" => "invalid_client"}}

    {_device, conn} =
      post(device(), "/device/token", %{
        grant_type: "password",
        device_code: codes["device_code"],
        client_id: "tv-app"
      })

    assert json(conn) == %{"error" => "unsupported_grant_type"}

    {_device, conn} = post(device(), "/device/token", %{grant_type: @grant, client_id: "tv-app"})
    assert {conn.status, json(conn)} == {400, %{"error" => "invalid_request"}}
  end

  test "approving needs a signed-in user", %{browser: browser} do
    codes = request_codes()
    {_browser, conn} = post(browser, "/device/approve", %{user_code: codes["user_code"]})
    assert conn.status == 401
  end

  test "codes bound to a user in advance", %{browser: _browser} do
    ada = signed_in()
    {_ada, conn} = get(ada, "/get-session")
    ada_id = json(conn)["user"]["id"]

    {:ok, codes} = DeviceAuthorization.create(Auth, "tv-app", user_id: ada_id)

    {_grace, conn} =
      post(signed_in("grace@example.com"), "/device/approve", %{user_code: codes.user_code})

    assert conn.status == 403
    {_ada, conn} = post(ada, "/device/approve", %{user_code: codes.user_code})
    assert json(conn) == %{"success" => true}
  end

  @tag auth: JWTAuth
  test "JWTs instead of session tokens", %{browser: browser} do
    {phone, _user} = sign_up(browser)
    codes = request_codes(JWTAuth)
    {_phone, _conn} = post(phone, "/device/approve", %{user_code: codes["user_code"]})

    {200, token} = poll(codes["device_code"], "tv-app", JWTAuth)

    assert {:ok, %{"email" => "ada@example.com"}} =
             JWT.verify(JWTAuth, token["access_token"])
  end
end
