defmodule Authmk.SAMLSignatureTest do
  # Responses signed by xmlsec1 (test/fixtures/saml/generate.sh), an
  # independent XML signature implementation, at a fixed time: these check
  # authmk's canonicalization and verification against it, and against
  # known signature-wrapping attacks. The sign-in flow is in sso_saml_test.
  use ExUnit.Case, async: true

  alias Authmk.Plugins.SSO.SAML.{C14N, Certificates, Response, XML}
  alias Authmk.Test.SAMLIdP

  defp expected(certificate \\ SAMLIdP.certificate()) do
    {:ok, certificate} = Certificates.parse(certificate)

    %{
      issuer: "https://idp.acme.example/saml",
      certificates: [certificate],
      audience: "http://localhost:4000/auth/sso/saml2/metadata/acme",
      recipient: "http://localhost:4000/auth/sso/saml2/acs/acme",
      now: ~U[2026-01-01 10:01:00Z],
      clock_skew: 120
    }
  end

  defp validate(xml, expected \\ expected()), do: Response.validate(Base.encode64(xml), expected)

  test "responses xmlsec1 signed: RSA, ECDSA, prefix lists, whole responses" do
    for file <- ~w(response-rsa.xml response-prefixlist.xml response-signed.xml) do
      assert {:ok, identity} = validate(SAMLIdP.fixture(file)), file
      assert identity.name_id == "ada@acme.example"
      assert identity.in_response_to == "_request1"
      assert identity.attributes["groups"] == ["admins", "staff"]
    end

    ec = SAMLIdP.fixture("response-ec.xml")
    assert {:ok, _identity} = validate(ec, expected(SAMLIdP.other_certificate()))

    # Another key than the provider's doesn't do.
    assert validate(ec) == {:error, :invalid_signature}

    assert validate(SAMLIdP.fixture("response-rsa.xml"), expected(SAMLIdP.other_certificate())) ==
             {:error, :invalid_signature}
  end

  test "canonicalization matches libxml2's" do
    {:ok, root} = XML.parse(SAMLIdP.fixture("c14n-input.xml"))
    assert C14N.canonicalize(root) == SAMLIdP.fixture("c14n-expected.xml")
  end

  test "time limits, with clock skew" do
    xml = SAMLIdP.fixture("response-rsa.xml")
    assert {:ok, _identity} = validate(xml, %{expected() | now: ~U[2026-01-01 10:06:59Z]})
    assert validate(xml, %{expected() | now: ~U[2026-01-01 10:07:00Z]}) == {:error, :expired}

    assert validate(xml, %{expected() | now: ~U[2026-01-01 09:55:00Z]}) ==
             {:error, :not_yet_valid}
  end

  test "signature wrapping: only the signed assertion counts" do
    xml = SAMLIdP.fixture("response-rsa.xml")
    [signed] = Regex.run(~r{<saml:Assertion .*</saml:Assertion>}s, xml)
    forged = String.replace(signed, ">ada@acme.example<", ">eve@acme.example<")

    # An unsigned assertion next to the signed one.
    two = String.replace(xml, signed, forged <> signed)
    assert validate(two) == {:error, :invalid_xml}

    forged_id = String.replace(forged, ~s(ID="_assertion1"), ~s(ID="_evil"))
    assert validate(String.replace(xml, signed, forged_id <> signed)) == {:error, :no_assertion}

    # The signed assertion hidden inside a forged one.
    unsigned_outer =
      String.replace(forged_id, "</saml:Assertion>", signed <> "</saml:Assertion>", global: false)

    # Its copied signature names the inner assertion, not the outer one.
    assert validate(String.replace(xml, signed, unsigned_outer)) == {:error, :invalid_signature}

    # The forged assertion carrying the real signature.
    assert validate(String.replace(xml, signed, forged)) == {:error, :invalid_signature}

    # A comment splitting the NameID changes nothing the signature covers,
    # and the whole text is read.
    commented = String.replace(xml, ">ada@acme.example<", ">ada@acme.example<!-- x --><")
    assert {:ok, %{name_id: "ada@acme.example"}} = validate(commented)

    split =
      String.replace(
        xml,
        "<saml:NameID Format=\"urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress\">ada@acme.example",
        "<saml:NameID Format=\"urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress\">ada@acme.example<!---->.evil.example"
      )

    assert validate(split) == {:error, :invalid_signature}
  end

  test "weak or unknown algorithms are refused" do
    xml = SAMLIdP.fixture("response-rsa.xml")

    sha1 =
      String.replace(
        xml,
        "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
        "http://www.w3.org/2000/09/xmldsig#rsa-sha1"
      )

    assert validate(sha1) == {:error, :invalid_signature}

    sha1_digest =
      String.replace(
        xml,
        "http://www.w3.org/2001/04/xmlenc#sha256",
        "http://www.w3.org/2000/09/xmldsig#sha1"
      )

    assert validate(sha1_digest) == {:error, :invalid_signature}
  end

  test "encrypted assertions are refused plainly" do
    xml = SAMLIdP.fixture("response-rsa.xml")
    [signed] = Regex.run(~r{<saml:Assertion .*</saml:Assertion>}s, xml)
    encrypted = String.replace(xml, signed, "<saml:EncryptedAssertion/>")
    assert validate(encrypted) == {:error, :encrypted_assertion}
  end
end
