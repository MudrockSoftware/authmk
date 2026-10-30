defmodule Authmk.SSOSAMLTest do
  use Authmk.EmulationCase, async: true

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Authmk.Plugins.SSO.SAML.{Certificates, XML}
  alias Authmk.Test.{Browser, Repo, SAMLIdP}

  @base "http://localhost:4000/auth"
  @acs @base <> "/sso/saml2/acs/okta"
  @audience @base <> "/sso/saml2/metadata/okta"

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.SSO,
         can_manage: &__MODULE__.can_manage?/3,
         saml: [
           signing_keys: [
             [
               private_key: File.read!("test/fixtures/saml/sp-rsa.key"),
               certificate: File.read!("test/fixtures/saml/sp-rsa.crt")
             ],
             # The previous key, still published while providers move over.
             [
               private_key: File.read!("test/fixtures/saml/idp-rsa.key"),
               certificate: File.read!("test/fixtures/saml/idp-rsa.crt")
             ]
           ]
         ],
         default_providers: [
           [
             provider_id: "okta",
             domain: "acme.example",
             saml: [
               entity_id: "https://idp.acme.example/saml",
               sso_url: "https://idp.acme.example/sso?app=1",
               certificates: [File.read!("test/fixtures/saml/idp-rsa.crt")]
             ]
           ],
           [
             provider_id: "portal",
             saml: [
               entity_id: "https://idp.acme.example/saml",
               sso_url: "https://idp.acme.example/sso",
               certificates: [File.read!("test/fixtures/saml/idp-rsa.crt")],
               allow_idp_initiated: true
             ]
           ]
         ]}
      ]

    def can_manage?(_action, _organization_id, _ctx), do: true
  end

  @moduletag auth: Auth

  # Starts a sign-in: the AuthnRequest the identity provider would get.
  defp start(browser, provider_id \\ "okta") do
    {browser, conn} =
      post(browser, "/sign-in/sso", %{provider_id: provider_id, callback_url: "/done"})

    url = json(conn)["url"] || flunk(inspect(json(conn)))
    {browser, url, URI.decode_query(URI.parse(url).query)}
  end

  defp request_xml(query) do
    query["SAMLRequest"] |> Base.decode64!() |> :zlib.unzip()
  end

  defp request_id(query) do
    [_, id] = Regex.run(~r/ ID="([^"]+)"/, request_xml(query))
    id
  end

  # The identity provider's page posts the response: cross-site, so the
  # browser sends none of our SameSite=Lax cookies.
  defp post_to_acs(response, relay_state, path \\ "/sso/saml2/acs/okta") do
    idp_page = Browser.new(Auth, origin: "https://idp.acme.example")

    {_idp_page, conn} =
      Browser.post_form(idp_page, path, %{SAMLResponse: response, RelayState: relay_state})

    redirected_to(conn)
  end

  defp follow(browser, location) do
    {browser, conn} =
      get(
        browser,
        String.replace_prefix(URI.parse(location).path, "/auth", ""),
        URI.decode_query(URI.parse(location).query || "")
      )

    {browser, redirected_to(conn)}
  end

  defp signed_in_email(browser) do
    {_browser, conn} = get(browser, "/get-session")
    (json(conn) || %{})["user"]["email"]
  end

  # Refused for `reason`, which only the server's log tells.
  defp refused(response, reason, relay_state \\ "anything") do
    log =
      capture_log(fn ->
        location = post_to_acs(response, relay_state)
        assert location =~ "/auth/error?error=invalid_saml_response"
      end)

    assert log =~ "(#{reason})"
  end

  test "sign in from the service provider: request, response, finish", %{browser: browser} do
    {browser, url, query} = start(browser)

    # The provider's own query is kept; the request is signed.
    assert url =~ "https://idp.acme.example/sso?app=1&SAMLRequest="
    xml = request_xml(query)
    assert xml =~ ~s(AssertionConsumerServiceURL="#{@acs}")
    assert xml =~ "<saml:Issuer>#{@audience}</saml:Issuer>"

    signed =
      "SAMLRequest=#{URI.encode_www_form(query["SAMLRequest"])}&RelayState=#{URI.encode_www_form(query["RelayState"])}&SigAlg=#{URI.encode_www_form(query["SigAlg"])}"

    {:ok, %{key: {:rsa, key}}} = Certificates.parse(File.read!("test/fixtures/saml/sp-rsa.crt"))
    assert :public_key.verify(signed, :sha256, Base.decode64!(query["Signature"]), key)

    response =
      SAMLIdP.response(in_response_to: request_id(query), acs_url: @acs, audience: @audience)

    location = post_to_acs(response, query["RelayState"])
    assert location =~ "#{@base}/sso/saml2/finish?code="

    {browser, destination} = follow(browser, location)
    assert destination == "/done"
    assert signed_in_email(browser) == "ada@acme.example"

    assert [%{account_id: "ada@acme.example"}] =
             Repo.all(
               from(a in "accounts",
                 where: a.provider_id == "sso:okta",
                 select: %{account_id: a.account_id}
               )
             )

    # The same response again: refused, it has been used.
    refused(response, :replayed, query["RelayState"])
  end

  test "a response only finishes in the browser that asked for it", %{browser: browser} do
    {_attacker, _url, query} = start(Browser.new(Auth))

    response =
      SAMLIdP.response(
        in_response_to: request_id(query),
        acs_url: @acs,
        audience: @audience,
        name_id: "eve@acme.example",
        attributes: %{"email" => ["eve@acme.example"]}
      )

    location = post_to_acs(response, query["RelayState"])

    # The victim, sent to the attacker's finish link, with a flow of their own.
    {victim, _url, _query} = start(browser)
    {victim, destination} = follow(victim, location)
    assert destination =~ "/auth/error?error=state_mismatch"
    assert signed_in_email(victim) == nil

    # Answers to no request are refused for providers that don't allow it.
    unsolicited = SAMLIdP.response(acs_url: @acs, audience: @audience)
    refused(unsolicited, :idp_initiated)
  end

  test "responses that aren't right are refused, each for its reason", %{browser: browser} do
    {_browser, _url, query} = start(browser)
    good = [in_response_to: request_id(query), acs_url: @acs, audience: @audience]
    response = &SAMLIdP.response(Keyword.merge(good, &1))
    expired = DateTime.add(DateTime.utc_now(), -600)

    # Changed after signing.
    tampered =
      [] |> response.() |> Base.decode64!() |> String.replace("ada@", "eve@") |> Base.encode64()

    # External entities never get read.
    xxe =
      Base.encode64(
        ~s(<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">&x;</samlp:Response>)
      )

    for {bad, reason} <- [
          {response.(sign: :none), :unsigned},
          {response.(audience: @base <> "/sso/saml2/metadata/portal"), :invalid_audience},
          {response.(sign: :response, audience: "elsewhere"), :invalid_audience},
          {response.(acs_url: @base <> "/sso/saml2/acs/portal"), :invalid_destination},
          {response.(issuer: "https://evil.example"), :invalid_issuer},
          {response.(not_on_or_after: expired), :expired},
          {response.(status: "urn:oasis:names:tc:SAML:2.0:status:Responder"), :saml_status},
          {tampered, :invalid_signature},
          {xxe, :invalid_xml},
          {"not base64!", :invalid_encoding},
          {String.duplicate("A", 300_000), :too_large}
        ] do
      refused(bad, reason)
    end

    # A response signed as a whole, for the right request, still works.
    location = post_to_acs(response.(sign: :response), query["RelayState"])
    assert location =~ "/sso/saml2/finish?code="
  end

  test "sign in from the identity provider, when the provider allows it", %{browser: browser} do
    acs = @base <> "/sso/saml2/acs/portal"
    audience = @base <> "/sso/saml2/metadata/portal"

    location =
      post_to_acs(
        SAMLIdP.response(acs_url: acs, audience: audience),
        "/welcome",
        "/sso/saml2/acs/portal"
      )

    {browser, destination} = follow(browser, location)
    assert destination == "/welcome"
    assert signed_in_email(browser) == "ada@acme.example"

    # RelayState can't send users off-site.
    location =
      post_to_acs(
        SAMLIdP.response(acs_url: acs, audience: audience),
        "https://evil.example/",
        "/sso/saml2/acs/portal"
      )

    {_browser, destination} = follow(Browser.new(Auth), location)
    assert destination == "/"
  end

  test "the service provider's metadata, with every signing certificate", %{browser: browser} do
    {_browser, conn} = get(browser, "/sso/saml2/metadata/okta")
    assert conn.status == 200
    assert ["application/samlmetadata+xml" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    {:ok, metadata} = XML.parse(conn.resp_body)
    assert XML.attr(metadata, "entityID") == @audience
    assert conn.resp_body =~ ~s(Location="#{@acs}")
    assert conn.resp_body =~ ~s(AuthnRequestsSigned="true")
    assert length(Regex.scan(~r/<ds:X509Certificate>/, conn.resp_body)) == 2

    {_browser, conn} = get(browser, "/sso/saml2/metadata/nope")
    assert conn.status == 404
  end

  test "register a SAML provider from its metadata, with an attribute mapping", %{
    browser: browser
  } do
    {owner, _user} = sign_up(browser, %{email: "owner@other.example"})

    certificate =
      SAMLIdP.certificate()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.join()

    metadata = """
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="https://idp.globex.example/saml">
      <md:IDPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:X509Data><ds:X509Certificate>#{certificate}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="https://idp.globex.example/post"/>
        <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="https://idp.globex.example/redirect"/>
      </md:IDPSSODescriptor>
    </md:EntityDescriptor>
    """

    {owner, conn} =
      post(owner, "/sso/register", %{
        provider_id: "globex",
        saml_config: %{metadata: metadata, mapping: %{email: "mailAddress", name: "fullName"}}
      })

    assert %{
             "type" => "saml",
             "issuer" => "https://idp.globex.example/saml",
             "saml" => %{
               "sso_url" => "https://idp.globex.example/redirect",
               "acs_url" => @base <> "/sso/saml2/acs/globex",
               "metadata_url" => @base <> "/sso/saml2/metadata/globex"
             }
           } = json(conn)

    # Checked: HTTPS sign-on URLs, real certificates, one kind of config.
    for bad <- [
          %{
            saml_config: %{
              entity_id: "x",
              sso_url: "http://idp.example/sso",
              certificate: SAMLIdP.certificate()
            }
          },
          %{
            saml_config: %{
              entity_id: "x",
              sso_url: "https://idp.example/sso",
              certificate: "nope"
            }
          },
          %{saml_config: %{metadata: "<!DOCTYPE x><x/>"}},
          %{
            saml_config: %{metadata: metadata},
            oidc_config: %{client_id: "a", client_secret: "b"}
          }
        ] do
      {_owner, conn} = post(owner, "/sso/register", Map.put(bad, :provider_id, "bad"))
      assert conn.status == 400, inspect(bad)
    end

    # The testing helper reads the request from the sign-in URL.
    {browser, url, _query} = start(Browser.new(Auth), "globex")

    %{acs_url: acs_url, params: params} =
      Authmk.Testing.SAMLIdP.response(url,
        issuer: "https://idp.globex.example/saml",
        private_key: SAMLIdP.fixture("idp-rsa.key"),
        name_id: "G-42",
        attributes: %{"mailAddress" => ["grace@globex.example"], "fullName" => ["Grace Hopper"]}
      )

    assert acs_url == @base <> "/sso/saml2/acs/globex"
    location = post_to_acs(params["SAMLResponse"], params["RelayState"], "/sso/saml2/acs/globex")
    {browser, "/done"} = follow(browser, location)
    assert signed_in_email(browser) == "grace@globex.example"

    assert [%{name: "Grace Hopper"}] =
             Repo.all(
               from(u in "users",
                 where: u.email == "grace@globex.example",
                 select: %{name: u.name}
               )
             )
  end
end
