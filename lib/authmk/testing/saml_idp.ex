defmodule Authmk.Testing.SAMLIdP do
  @moduledoc """
  A stand-in SAML identity provider for your tests: signed Responses for
  sign-ins your app starts, so the whole flow runs without a real IdP.

      # The provider's certificate (in config) and this key are a test pair.
      start = post(conn, "/auth/sign-in/sso", %{provider_id: "acme"})

      %{acs_url: acs_url, params: params} =
        Authmk.Testing.SAMLIdP.response(json_response(start, 200)["url"],
          issuer: "https://idp.acme.example/saml",
          private_key: File.read!("test/fixtures/idp.key"),
          name_id: "ada@acme.example",
          attributes: %{"email" => ["ada@acme.example"]}
        )

      # The IdP's page posts `params` to `acs_url` (a form, without your
      # cookies), then the browser follows the redirect with them.

  Responses are signed like real ones: exclusive canonicalization, RSA with
  SHA-256, an enveloped signature on the Assertion (or the Response, with
  `sign: :response`). Use this module in tests only.
  """

  alias Authmk.Plugins.SSO.SAML.{C14N, XML}

  @doc """
  The Response to the AuthnRequest in `sign_in_url` (the `url` that
  `POST /sign-in/sso` answers with): the ACS URL to post it to, and the form
  params (`"SAMLResponse"`, `"RelayState"`).

  Options: `:issuer` and `:private_key` (PEM), required; `:name_id`
  (default `"user@example.com"`), `:attributes` (`%{name => [value]}`), and
  those of `build/1`.
  """
  @spec response(String.t(), keyword()) :: %{acs_url: String.t(), params: map()}
  def response(sign_in_url, opts) do
    query = URI.decode_query(URI.parse(sign_in_url).query || "")
    request = query["SAMLRequest"] |> Base.decode64!() |> :zlib.unzip()
    [_, id] = Regex.run(~r/ ID="([^"]+)"/, request)
    [_, acs_url] = Regex.run(~r/ AssertionConsumerServiceURL="([^"]+)"/, request)
    [_, audience] = Regex.run(~r{<saml:Issuer>([^<]+)</saml:Issuer>}, request)

    response =
      build(Keyword.merge([in_response_to: id, acs_url: acs_url, audience: audience], opts))

    %{
      acs_url: acs_url,
      params: %{"SAMLResponse" => response, "RelayState" => query["RelayState"]}
    }
  end

  @doc """
  A base64 Response from explicit values, like an IdP-initiated one (no
  `:in_response_to`). Options: `:issuer`, `:private_key`, `:acs_url`,
  `:audience` (required); `:in_response_to`, `:name_id`, `:attributes`,
  `:sign` (`:assertion`, `:response` or `:none`), `:not_on_or_after`,
  `:assertion_id`, `:status`.
  """
  @spec build(keyword()) :: String.t()
  def build(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    opts = Keyword.merge(defaults(now), opts)
    key = private_key(Keyword.fetch!(opts, :private_key))

    xml =
      case opts[:sign] do
        :assertion -> document(opts, signed_assertion(opts, key), "")
        :response -> signed_response(opts, key)
        :none -> document(opts, assertion(opts, ""), "")
      end

    Base.encode64(xml)
  end

  defp defaults(now) do
    [
      in_response_to: nil,
      name_id: "user@example.com",
      attributes: %{},
      sign: :assertion,
      not_on_or_after: DateTime.add(now, 300),
      assertion_id: "_a" <> Integer.to_string(System.unique_integer([:positive])),
      status: "urn:oasis:names:tc:SAML:2.0:status:Success",
      now: now
    ]
  end

  defp private_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp document(opts, assertion, signature) do
    ~s(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ) <>
      ~s(xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="_r#{opts[:assertion_id]}" ) <>
      ~s(Version="2.0" IssueInstant="#{opts[:now]}" Destination="#{escape(opts[:acs_url])}") <>
      in_response_to(opts) <>
      ~s(><saml:Issuer>#{escape(opts[:issuer])}</saml:Issuer>) <>
      signature <>
      ~s(<samlp:Status><samlp:StatusCode Value="#{opts[:status]}"/></samlp:Status>) <>
      assertion <> "</samlp:Response>"
  end

  defp assertion(opts, signature) do
    ~s(<saml:Assertion ID="#{opts[:assertion_id]}" Version="2.0" IssueInstant="#{opts[:now]}">) <>
      ~s(<saml:Issuer>#{escape(opts[:issuer])}</saml:Issuer>) <>
      signature <>
      ~s(<saml:Subject><saml:NameID Format="urn:oasis:names:tc:SAML:2.0:nameid-format:persistent">) <>
      escape(opts[:name_id]) <>
      ~s(</saml:NameID><saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">) <>
      ~s(<saml:SubjectConfirmationData NotOnOrAfter="#{opts[:not_on_or_after]}" ) <>
      ~s(Recipient="#{escape(opts[:acs_url])}") <>
      in_response_to(opts) <>
      ~s(/></saml:SubjectConfirmation></saml:Subject>) <>
      ~s(<saml:Conditions NotBefore="#{DateTime.add(opts[:now], -60)}" ) <>
      ~s(NotOnOrAfter="#{opts[:not_on_or_after]}"><saml:AudienceRestriction>) <>
      ~s(<saml:Audience>#{escape(opts[:audience])}</saml:Audience>) <>
      ~s(</saml:AudienceRestriction></saml:Conditions>) <>
      ~s(<saml:AuthnStatement AuthnInstant="#{opts[:now]}" SessionIndex="_s1"/>) <>
      ~s(<saml:AttributeStatement>#{attributes(opts[:attributes])}</saml:AttributeStatement>) <>
      "</saml:Assertion>"
  end

  defp in_response_to(opts) do
    if opts[:in_response_to], do: ~s( InResponseTo="#{escape(opts[:in_response_to])}"), else: ""
  end

  defp attributes(attributes) do
    for {name, values} <- attributes, into: "" do
      ~s(<saml:Attribute Name="#{escape(name)}">) <>
        Enum.map_join(values, &"<saml:AttributeValue>#{escape(&1)}</saml:AttributeValue>") <>
        "</saml:Attribute>"
    end
  end

  defp signed_assertion(opts, key) do
    {:ok, root} = XML.parse(document(opts, assertion(opts, ""), ""))
    element = XML.child(root, "urn:oasis:names:tc:SAML:2.0:assertion", "Assertion")
    assertion(opts, signature(element, opts[:assertion_id], key))
  end

  defp signed_response(opts, key) do
    {:ok, root} = XML.parse(document(opts, assertion(opts, ""), ""))
    document(opts, assertion(opts, ""), signature(root, "_r" <> opts[:assertion_id], key))
  end

  # An enveloped signature over `element`, whose ID is `id`.
  defp signature(element, id, key) do
    digest = :sha256 |> :crypto.hash(C14N.canonicalize(element)) |> Base.encode64()

    signed_info =
      ~s(<ds:SignedInfo>) <>
        ~s(<ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>) <>
        ~s(<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>) <>
        ~s(<ds:Reference URI="##{id}"><ds:Transforms>) <>
        ~s(<ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>) <>
        ~s(<ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms>) <>
        ~s(<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>) <>
        ~s(<ds:DigestValue>#{digest}</ds:DigestValue></ds:Reference></ds:SignedInfo>)

    # Canonicalized where it will sit: inside a Signature that declares ds.
    {:ok, wrapper} = XML.parse(wrap(signed_info))

    [signed_info_element] =
      XML.children(wrapper, "http://www.w3.org/2000/09/xmldsig#", "SignedInfo")

    value =
      signed_info_element
      |> C14N.canonicalize()
      |> :public_key.sign(:sha256, key)
      |> Base.encode64()

    wrap(signed_info <> ~s(<ds:SignatureValue>#{value}</ds:SignatureValue>))
  end

  defp wrap(inner),
    do:
      ~s(<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">) <>
        inner <> "</ds:Signature>"

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end
end
