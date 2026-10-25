defmodule Authmk.Fuzz.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.TwoFactor,
      {Authmk.Plugins.PhoneNumber,
       send_otp: &__MODULE__.send_sms/2, sign_up_on_verification: true}
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
