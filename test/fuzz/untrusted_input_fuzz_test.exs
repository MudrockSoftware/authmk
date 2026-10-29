defmodule Authmk.Fuzz.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.TwoFactor,
      {Authmk.Plugins.PhoneNumber,
       send_otp: &__MODULE__.send_sms/2, sign_up_on_verification: true},
      Authmk.Plugins.Passkey,
      Authmk.Plugins.SIWE,
      {Authmk.Plugins.APIKey, enable_sessions: true},
      Authmk.Plugins.JWT,
      Authmk.Plugins.DeviceAuthorization,
      {Authmk.Plugins.LastSignInMethod, store_in_database: true}
    ],
    base_url: "http://localhost:4000",
    trusted_origins: ["https://app.example.com"],
    background: :inline,
    rate_limit: [enabled: false],
    advanced: [ip_address_headers: ["x-forwarded-for"]]

  def send_sms(_message, _ctx), do: :ok
end

defmodule Authmk.UntrustedInputFuzzTest do
  use Authmk.EmulationCase, async: true
  use ExUnitProperties

  alias Authmk.Plugins.{JWT, LastSignInMethod}
  alias Authmk.Test.Browser
  alias Authmk.Testing.{FakeAuthenticator, FakeWallet}

  @moduletag :fuzz
  @moduletag auth: Authmk.Fuzz.Auth

  @trusted ["http://localhost:4000", "https://app.example.com"]

  property "redirects only ever go to relative paths or trusted origins", %{browser: browser} do
    check all(url <- callback_url()) do
      {_browser, conn} = get(browser, "/verify-email", %{token: "bad", callback_url: url})

      case conn.status do
        302 ->
          location = redirected_to(conn)
          assert safe_location?(location), "redirected to #{inspect(location)}"

        403 ->
          assert json(conn)["error"]["code"] == "invalid_callback_url"

        # A blank URL means no redirect at all.
        400 ->
          assert String.trim(url) == ""
          assert json(conn)["error"]["code"] == "invalid_token"
      end
    end
  end

  property "any path and method gets a JSON answer, never a crash", %{browser: browser} do
    check all(
            segments <- list_of(string(:printable, max_length: 20), max_length: 4),
            method <- member_of([:get, :post])
          ) do
      path = "/" <> Enum.map_join(segments, "/", &URI.encode_www_form/1)
      {_browser, conn} = request(browser, method, path, %{})

      assert conn.status in [200, 302, 400, 401, 404, 422]
      assert conn.status == 302 or is_map(json(conn)) or is_nil(json(conn)) or is_list(json(conn))
    end
  end

  property "garbage proxy headers fall back to the socket address", %{browser: browser} do
    check all(header <- string(:printable, max_length: 60)) do
      browser = %{browser | headers: [{"x-forwarded-for", header}]}
      {_browser, conn} = get(browser, "/ok")
      assert conn.status == 200
    end
  end

  property "random session cookies never sign anyone in", %{browser: browser} do
    check all(token <- string(:printable, max_length: 64)) do
      browser = %{browser | cookies: %{"authmk.session_token" => token}}
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn) == nil
    end
  end

  property "forged 2FA cookies and codes never sign anyone in", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/two-factor/enable", %{password: "correct horse"})
    secret = json(conn)["totp_uri"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    secret = Base.decode32!(secret["secret"], padding: false)

    {browser, _conn} =
      post(browser, "/two-factor/verify-totp", %{code: NimbleTOTP.verification_code(secret)})

    {stranger, _conn} = post(browser, "/sign-out")

    check all(
            challenge <- string(:printable, max_length: 80),
            trust <- string(:printable, max_length: 80),
            code <- string(:alphanumeric, max_length: 12),
            path <-
              member_of([
                "/two-factor/verify-totp",
                "/two-factor/verify-otp",
                "/two-factor/verify-backup-code"
              ])
          ) do
      forged = %{
        stranger
        | cookies: %{"authmk.two_factor" => challenge, "authmk.trust_device" => trust}
      }

      {forged, conn} = post(forged, path, %{code: code})
      assert conn.status in [400, 401, 422, 429]

      {forged, conn} =
        post(forged, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

      assert json(conn)["two_factor_redirect"] == true

      {_forged, conn} = get(forged, "/get-session")
      assert json(conn) == nil
    end
  end

  property "guessed phone codes never sign anyone in", %{browser: browser} do
    {browser, _conn} = post(browser, "/phone-number/send-otp", %{phone_number: "+14155550123"})

    check all(
            number <- one_of([constant("+14155550123"), string(:printable, max_length: 20)]),
            code <- string(:printable, max_length: 10)
          ) do
      {browser, conn} = post(browser, "/phone-number/verify", %{phone_number: number, code: code})
      assert conn.status in [400, 403, 422]

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn) == nil
    end
  end

  property "garbled passkey responses never crash or sign anyone in", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    authenticator = FakeAuthenticator.new()
    {browser, conn} = post(browser, "/passkey/generate-register-options")
    registration = FakeAuthenticator.register(authenticator, json(conn))
    {browser, _conn} = post(browser, "/passkey/verify-registration", %{response: registration})
    {stranger, _conn} = post(browser, "/sign-out")

    check all(
            field <- member_of(["clientDataJSON", "authenticatorData", "signature"]),
            value <-
              one_of([
                map(binary(max_length: 200), &Base.url_encode64(&1, padding: false)),
                string(:printable, max_length: 200)
              ])
          ) do
      {stranger, conn} = post(stranger, "/passkey/generate-authenticate-options")
      {_moved, response} = FakeAuthenticator.authenticate(authenticator, json(conn))
      response = put_in(response, ["response", field], value)

      {stranger, conn} = post(stranger, "/passkey/verify-authentication", %{response: response})
      assert conn.status in [400, 401]

      {_stranger, conn} = get(stranger, "/get-session")
      assert json(conn) == nil
    end
  end

  property "mangled sign-in messages and signatures never crash or sign anyone in", %{
    browser: browser
  } do
    wallet = FakeWallet.new()

    check all(
            cut <- integer(0..400),
            insert <- string(:printable, max_length: 30),
            signature <-
              one_of([
                string(:printable, max_length: 140),
                map(binary(max_length: 70), &("0x" <> Base.encode16(&1)))
              ])
          ) do
      {browser, conn} = post(browser, "/siwe/nonce", %{wallet_address: wallet.address})
      message = FakeWallet.message(wallet, domain: "localhost:4000", nonce: json(conn)["nonce"])
      # The real message with a piece cut out and something else put in.
      {head, tail} = String.split_at(message, cut)
      mangled = head <> insert <> String.slice(tail, String.length(insert)..-1//1)

      {browser, conn} =
        post(browser, "/siwe/verify", %{
          message: mangled,
          signature: signature,
          wallet_address: wallet.address
        })

      assert conn.status in [400, 401, 422]

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn) == nil
    end
  end

  property "random API keys in the header never sign anyone in", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, _conn} = post(browser, "/api-key/create", %{name: "real"})

    check all(key <- string(:printable, min_length: 1, max_length: 100)) do
      stranger = %{Browser.new(Authmk.Fuzz.Auth) | headers: [{"x-api-key", key}]}
      {_stranger, conn} = get(stranger, "/get-session")
      assert conn.status == 401
    end
  end

  property "mangled JWTs never verify or crash", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = get(browser, "/token")
    token = json(conn)["token"]

    check all(
            cut <- integer(0..400),
            insert <- string(:printable, max_length: 20),
            random <- string(:printable, max_length: 200)
          ) do
      {head, tail} = String.split_at(token, cut)
      mangled = head <> insert <> String.slice(tail, String.length(insert)..-1//1)

      # The last base64url characters have spare bits: changing them can
      # decode to the same signature, so the mangling stays clear of them.
      candidates =
        if cut + String.length(insert) < byte_size(token) - 3,
          do: [random, mangled],
          else: [random]

      for candidate <- candidates, candidate != token do
        assert {:error, _error} = JWT.verify(Authmk.Fuzz.Auth, candidate)
      end
    end
  end

  property "only plain method names come back from the last sign-in cookie", %{browser: _browser} do
    check all(value <- string(:printable, max_length: 80)) do
      conn =
        Plug.Test.put_req_cookie(Plug.Test.conn(:get, "/"), "authmk.last_sign_in_method", value)

      case LastSignInMethod.get(conn, Authmk.Fuzz.Auth) do
        nil -> :ok
        method -> assert method =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/
      end
    end
  end

  property "made-up device and user codes get nowhere", %{browser: browser} do
    {_browser, conn} = post(browser, "/device/code", %{client_id: "tv"})
    assert conn.status == 200
    {browser, _user} = sign_up(browser)

    check all(
            code <- string(:printable, max_length: 60),
            grant <-
              one_of([
                constant("urn:ietf:params:oauth:grant-type:device_code"),
                string(:printable, max_length: 30)
              ])
          ) do
      {_device, conn} =
        post(Browser.new(Authmk.Fuzz.Auth), "/device/token", %{
          grant_type: grant,
          device_code: code,
          client_id: "tv"
        })

      assert conn.status == 400
      refute Map.has_key?(json(conn), "access_token")

      {_browser, conn} = post(browser, "/device/approve", %{user_code: code})
      assert conn.status in [400, 404, 422]
    end
  end

  defp callback_url do
    one_of([
      string(:printable, max_length: 40),
      map(
        {member_of(["/", "//", "/\\", "http://", "https://", "javascript:", " /"]),
         string(:printable, max_length: 30)},
        fn
          {prefix, rest} -> prefix <> rest
        end
      ),
      map({member_of(@trusted), string(:printable, max_length: 20)}, fn {origin, rest} ->
        origin <> rest
      end)
    ])
  end

  defp safe_location?(location) do
    relative =
      String.starts_with?(location, "/") and not String.starts_with?(location, ["//", "/\\"])

    relative or Authmk.Origin.origin(location) in @trusted
  end
end
