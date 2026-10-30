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
      {Authmk.Plugins.LastSignInMethod, store_in_database: true},
      Authmk.Plugins.SCIM,
      {Authmk.Plugins.Stripe, api_key: "sk_test_fuzz", webhook_secret: "whsec_fuzz"},
      {Authmk.Plugins.SSO,
       default_providers: [
         [
           provider_id: "okta",
           saml: [
             entity_id: "https://idp.acme.example/saml",
             sso_url: "https://idp.acme.example/sso",
             certificates: [File.read!("test/fixtures/saml/idp-rsa.crt")]
           ]
         ]
       ]},
      # Client ID metadata documents on, with no DNS: URLs get checked, never fetched.
      {Authmk.Plugins.OAuthProvider,
       login_page: "/sign-in",
       consent_page: "/consent",
       client_id_metadata_documents: true,
       resolve_host: &__MODULE__.no_dns/1},
      # This server plays production for the OAuth proxy.
      {Authmk.Plugins.OAuthProxy,
       production_url: "http://localhost:4000", secret: "the fuzz proxy secret, 32+ bytes long"}
    ],
    base_url: "http://localhost:4000",
    trusted_origins: ["https://app.example.com"],
    background: :inline,
    rate_limit: [enabled: false],
    advanced: [ip_address_headers: ["x-forwarded-for"]]

  def send_sms(_message, _ctx), do: :ok
  def no_dns(_host), do: :error
end

defmodule Authmk.Fuzz.SecurityAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      {Authmk.Plugins.Security, proof_of_work: [endpoints: [:sign_up_email], difficulty: 24]}
    ],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.UntrustedInputFuzzTest do
  use Authmk.EmulationCase, async: true
  use ExUnitProperties

  alias Authmk.Plugins.{JWT, LastSignInMethod, OAuthProvider, SCIM}
  alias Authmk.Plugins.SSO.SAML.XML
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

  property "HTML forms only ever send the browser to safe places", %{browser: browser} do
    check all(
            success <- callback_url(),
            failure <- one_of([constant(nil), callback_url()]),
            referer <- one_of([constant(nil), callback_url()])
          ) do
      params = %{"authmk_redirect" => success, "email" => "nobody@example.com", "password" => "x"}
      params = if failure, do: Map.put(params, "authmk_error_redirect", failure), else: params

      browser =
        if referer,
          do: %{browser | headers: [{"referer", referer}]},
          else: %{browser | headers: []}

      {_browser, conn} = Browser.post_form(browser, "/sign-in/email", params)

      case conn.status do
        303 ->
          [location] = Plug.Conn.get_resp_header(conn, "location")
          assert safe_location?(location), "sent to #{inspect(location)}"

        # Not a form, or targets refused: JSON, and no redirect at all.
        _status ->
          assert Plug.Conn.get_resp_header(conn, "location") == []
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

  property "the OAuth proxy only sends codes back to trusted origins", %{browser: browser} do
    check all(
            to <- one_of([callback_url(), map(callback_url(), &(&1 <> "/callback/github"))]),
            signed? <- boolean(),
            junk <- string(:printable, max_length: 80)
          ) do
      state =
        if signed?,
          do:
            Plug.Crypto.sign("the fuzz proxy secret, 32+ bytes long", "authmk-oauth-proxy", %{
              "state" => junk,
              "to" => to
            }),
          else: junk

      {_browser, conn} = get(browser, "/callback/github", %{code: "c", state: state})
      location = redirected_to(conn)
      assert safe_location?(location), "redirected to #{inspect(location)}"
    end
  end

  property "garbage at the token endpoint never gets tokens", %{browser: _browser} do
    {:ok, client} =
      OAuthProvider.create_client(Authmk.Fuzz.Auth, %{
        "redirect_uris" => ["https://client.example/cb"],
        "grant_types" => ["authorization_code", "refresh_token", "client_credentials"],
        "scope" => "openid"
      })

    check all(
            grant <-
              one_of([
                member_of(~w(authorization_code refresh_token client_credentials)),
                string(:printable, max_length: 20)
              ]),
            code <- string(:printable, max_length: 60),
            verifier <- string(:printable, max_length: 130),
            authorization <-
              one_of([
                constant("Basic " <> Base.encode64(client.client_id <> ":wrong")),
                map(string(:printable, max_length: 60), &("Basic " <> &1)),
                map(binary(max_length: 40), &("Basic " <> Base.encode64(&1)))
              ])
          ) do
      server = %{
        Browser.new(Authmk.Fuzz.Auth)
        | headers: [{"authorization", authorization}],
          origin: nil
      }

      {_server, conn} =
        post(server, "/oauth2/token", %{
          grant_type: grant,
          code: code,
          refresh_token: code,
          code_verifier: verifier,
          redirect_uri: "https://client.example/cb"
        })

      assert conn.status in [400, 401]
      refute Map.has_key?(json(conn), "access_token")
    end
  end

  property "authorization requests only redirect to registered URIs or this site", %{
    browser: browser
  } do
    {:ok, client} =
      OAuthProvider.create_client(Authmk.Fuzz.Auth, %{
        "redirect_uris" => ["https://client.example/cb"],
        "scope" => "openid"
      })

    check all(
            client_id <-
              one_of([
                constant(client.client_id),
                string(:printable, max_length: 30),
                map(string(:printable, max_length: 40), &("https://" <> &1))
              ]),
            redirect_uri <- one_of([constant("https://client.example/cb"), callback_url()]),
            scope <- string(:printable, max_length: 30),
            challenge <- string(:printable, max_length: 64)
          ) do
      {_browser, conn} =
        get(browser, "/oauth2/authorize", %{
          response_type: "code",
          client_id: client_id,
          redirect_uri: redirect_uri,
          scope: scope,
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

      location = redirected_to(conn)

      assert String.starts_with?(location, "https://client.example/cb?") or
               String.starts_with?(location, "http://localhost:4000/"),
             "redirected to #{inspect(location)}"
    end
  end

  property "made-up client assertions and DPoP proofs never get tokens", %{browser: _browser} do
    {:ok, client} =
      OAuthProvider.create_client(Authmk.Fuzz.Auth, %{
        "grant_types" => ["client_credentials"],
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{
          "keys" => [
            %{
              "kty" => "EC",
              "crv" => "P-256",
              "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
              "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
            }
          ]
        }
      })

    jwt_like =
      one_of([
        string(:printable, max_length: 200),
        map(list_of(string(:alphanumeric, max_length: 60), length: 3), &Enum.join(&1, ".")),
        map(
          fixed_map(%{
            header:
              map_of(string(:alphanumeric, max_length: 5), string(:printable, max_length: 10),
                max_length: 3
              ),
            body: string(:printable, max_length: 40)
          }),
          &(Base.url_encode64(
              JSON.encode!(Map.merge(&1.header, %{"alg" => "ES256", "typ" => "dpop+jwt"})),
              padding: false
            ) <> "." <> Base.url_encode64(&1.body, padding: false) <> ".sig")
        )
      ])

    check all(assertion <- jwt_like, proof <- jwt_like) do
      {_client, conn} =
        post(
          %{Browser.new(Authmk.Fuzz.Auth) | origin: nil, headers: [{"dpop", proof}]},
          "/oauth2/token",
          %{
            grant_type: "client_credentials",
            client_id: client.client_id,
            client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            client_assertion: assertion
          }
        )

      assert conn.status in [400, 401]
      refute Map.has_key?(json(conn), "access_token")
    end
  end

  property "SCIM filters never crash, and bad ones are invalidFilter", %{browser: _browser} do
    {:ok, connection} =
      SCIM.create_connection(Authmk.Fuzz.Auth, organization_id: "org")

    directory = %{
      Browser.new(Authmk.Fuzz.Auth)
      | origin: nil,
        headers: [{"authorization", "Bearer " <> connection.token}]
    }

    attribute =
      member_of(
        ~w(userName externalId active emails.value name.familyName displayName password meta.created)
      )

    operator = member_of(~w(eq ne co sw ew pr gt EQ Co))

    value =
      one_of([
        map(string(:printable, max_length: 12), &inspect/1),
        member_of(~w(true false null 42 "a\\" "%" "_!"))
      ])

    comparison = map({attribute, operator, value}, fn {a, o, v} -> Enum.join([a, o, v], " ") end)

    grammar =
      map(
        list_of({comparison, member_of([" and ", " or ", " AND "]), boolean()},
          min_length: 1,
          max_length: 6
        ),
        fn parts ->
          Enum.map_join(parts, "", fn {term, joiner, wrap} ->
            if(wrap, do: "(" <> term <> ")", else: term) <> joiner
          end)
          |> String.replace_suffix(" and ", "")
        end
      )

    check all(filter <- one_of([string(:printable, max_length: 300), grammar])) do
      {_directory, conn} = Browser.request(directory, :get, "/scim/v2/Users", %{filter: filter})

      case conn.status do
        200 -> assert is_integer(json(conn)["totalResults"])
        400 -> assert json(conn)["scimType"] == "invalidFilter"
      end
    end
  end

  @tag auth: Authmk.Fuzz.SecurityAuth
  property "made-up proof-of-work never passes", %{browser: browser} do
    {_browser, conn} = get(browser, "/security/challenge")
    real = json(conn)["challenge"]

    check all(
            challenge <- one_of([constant(real), string(:printable, max_length: 120)]),
            nonce <- string(:alphanumeric, max_length: 80),
            email <- string(:printable, max_length: 60)
          ) do
      # At 24 bits, a random nonce solves it about once in 16 million tries.
      {_browser, conn} =
        post(
          %{browser | headers: [{"x-pow-challenge", challenge}, {"x-pow-nonce", nonce}]},
          "/sign-up/email",
          %{
            email: email,
            password: "correct horse",
            name: "A"
          }
        )

      assert conn.status != 200

      assert json(conn)["error"]["code"] in [
               "proof_of_work_required",
               "validation_failed",
               "invalid_email"
             ]
    end
  end

  property "the error page keeps any text inside its data block", %{browser: browser} do
    check all(
            error <- string(:printable, max_length: 120),
            description <- one_of([constant(nil), string(:printable, max_length: 200)])
          ) do
      params =
        if description, do: %{error: error, error_description: description}, else: %{error: error}

      {_browser, conn} = get(browser, "/error", params)

      [data] =
        Regex.run(
          ~r{<script type="application/json" id="authmk-page">(.*?)</script>}s,
          conn.resp_body,
          capture: :all_but_first
        )

      refute data =~ "<"
      page = JSON.decode!(data)
      if error != "", do: assert(page["code"] == error)
      if description not in [nil, ""], do: assert(page["message"] == description)
    end
  end

  # Real-looking responses, bent at random, and plain garbage.
  property "garbled SAML responses never crash or sign anyone in", %{browser: browser} do
    xml = File.read!("test/fixtures/saml/response-rsa.xml")

    check all(
            response <-
              one_of([
                binary(max_length: 400),
                map({integer(0..(byte_size(xml) - 1)), binary(min_length: 1, max_length: 8)}, fn
                  {at, bytes} ->
                    <<before::binary-size(^at), _::binary-size(1), rest::binary>> = xml
                    Base.encode64(before <> bytes <> rest)
                end)
              ])
          ) do
      {_idp_page, conn} =
        Browser.post_form(
          Browser.new(Authmk.Fuzz.Auth, origin: "https://idp.acme.example"),
          "/sso/saml2/acs/okta",
          %{
            SAMLResponse: response,
            RelayState: "x"
          }
        )

      # Unreadable bodies are a 400; readable ones, the error page.
      assert conn.status == 400 or redirected_to(conn) =~ "/auth/error?error="
      assert conn.resp_cookies |> Map.keys() |> Enum.all?(&(not String.contains?(&1, "session")))
    end

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil
  end

  property "garbled single logout messages never crash" do
    pieces =
      member_of(~w(SAMLRequest= SAMLResponse= RelayState= SigAlg= Signature= & %3D %2B fZ 3J +
                   http%3A%2F%2Fwww.w3.org%2F2001%2F04%2Fxmldsig-more%23rsa-sha256 AAAA ====))

    check all(parts <- list_of(pieces, max_length: 20)) do
      query = Enum.join(parts)
      conn = Plug.Test.conn(:get, "/auth/sso/saml2/slo/okta?" <> query)
      conn = Plug.forward(conn, ["sso", "saml2", "slo", "okta"], Authmk.Fuzz.Auth, [])

      assert conn.status in [302, 400]
      if conn.status == 302, do: assert(redirected_to(conn) =~ "/auth/error?error=")
    end
  end

  property "forged billing webhooks never get through" do
    check all(
            header <-
              one_of([
                string(:printable, max_length: 120),
                map({integer(), string(:alphanumeric, max_length: 64)}, fn {t, sig} ->
                  "t=#{t},v1=#{sig}"
                end)
              ]),
            body <-
              one_of([
                binary(max_length: 300),
                constant(
                  ~s({"type":"customer.subscription.created","data":{"object":{"id":"sub_1"}}})
                )
              ])
          ) do
      conn =
        Plug.Test.conn(:post, "/auth/billing/webhook", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", header)

      conn = Plug.forward(conn, ["billing", "webhook"], Authmk.Fuzz.Auth, [])
      assert conn.status == 400
    end
  end

  property "the XML reader never crashes, and never takes a DTD" do
    tokens =
      member_of(
        ~w(< > </ /> = " ' & &amp; &x; <!DOCTYPE <!ENTITY SYSTEM <![CDATA[ ]]> <!-- --> <? ?> a b:c xmlns xmlns:b ID ="x" text)
      )

    check all(pieces <- list_of(tokens, max_length: 40)) do
      xml = Enum.join(pieces, " ")

      case XML.parse(xml) do
        {:ok, _root} -> refute xml =~ "<!DOCTYPE"
        {:error, :invalid_xml} -> :ok
      end
    end
  end

  property "forged OAuth requests never continue", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    check all(oauth_query <- string(:printable, max_length: 200)) do
      {_browser, conn} = post(browser, "/oauth2/continue", %{oauth_query: oauth_query})
      assert json(conn)["error"]["code"] in ["invalid_oauth_query", "validation_failed"]
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
