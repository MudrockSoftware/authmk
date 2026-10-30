defmodule Authmk.Test.SAMLIdP do
  @moduledoc false
  # The test identity provider: Authmk.Testing.SAMLIdP with this suite's key
  # pair. The fixtures in test/fixtures/saml, signed by xmlsec1, check the
  # verifier independently of it.

  alias Authmk.Testing.SAMLIdP

  @fixtures "test/fixtures/saml/"

  def entity_id, do: "https://idp.acme.example/saml"
  def certificate, do: fixture("idp-rsa.crt")
  def other_certificate, do: fixture("idp-ec.crt")
  def fixture(name), do: File.read!(@fixtures <> name)

  @doc "A base64 Response; options as Authmk.Testing.SAMLIdP.build/1."
  def response(opts) do
    defaults = [
      issuer: entity_id(),
      private_key: fixture("idp-rsa.key"),
      name_id: "ada@acme.example",
      attributes: %{
        "email" => ["ada@acme.example"],
        "firstName" => ["Ada"],
        "lastName" => ["Lovelace"]
      }
    ]

    SAMLIdP.build(Keyword.merge(defaults, opts))
  end
end
