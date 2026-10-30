defmodule Authmk.Plugins.SSO.SAML.Request do
  @moduledoc false
  # The AuthnRequest that sends a user to the identity provider (HTTP-Redirect
  # binding): deflated, base64'd, in the query string, and signed when the
  # service provider has a signing key.

  alias Authmk.Plugins.SSO.SAML.Certificates
  alias Authmk.Token

  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"

  @doc "A new request ID. IDs are xs:ID: they must not start with a digit."
  def new_id, do: "_" <> Token.generate()

  @doc """
  The identity provider's URL with the request. `request`: `:id`, `:sso_url`,
  `:issuer` (our entity ID), `:acs_url`, `:relay_state`, `:signing_key` (or
  nil) and `:name_id_format`.
  """
  def redirect_url(request) do
    xml = authn_request(request.id, request)

    query =
      [{"SAMLRequest", deflate(xml)}, {"RelayState", request.relay_state}]
      |> sign(request.signing_key)
      |> Enum.map_join("&", fn {name, value} -> name <> "=" <> URI.encode_www_form(value) end)

    separator = if String.contains?(request.sso_url, "?"), do: "&", else: "?"
    request.sso_url <> separator <> query
  end

  defp authn_request(id, request) do
    instant = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    IO.iodata_to_binary([
      ~s(<samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ),
      ~s(xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ),
      ~s(ID="#{id}" Version="2.0" IssueInstant="#{instant}" ),
      ~s(Destination="#{escape(request.sso_url)}" ),
      ~s(AssertionConsumerServiceURL="#{escape(request.acs_url)}" ),
      ~s(ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">),
      ~s(<saml:Issuer>#{escape(request.issuer)}</saml:Issuer>),
      ~s(<samlp:NameIDPolicy Format="#{escape(request.name_id_format)}" AllowCreate="true"/>),
      ~s(</samlp:AuthnRequest>)
    ])
  end

  # The redirect binding signs the query string itself, in this order.
  defp sign(params, nil), do: params

  defp sign(params, key) do
    params = params ++ [{"SigAlg", @rsa_sha256}]

    signed =
      Enum.map_join(params, "&", fn {name, value} -> name <> "=" <> URI.encode_www_form(value) end)

    params ++ [{"Signature", Base.encode64(Certificates.sign(signed, key))}]
  end

  defp deflate(xml) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = :zlib.deflate(z, xml, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    compressed |> IO.iodata_to_binary() |> Base.encode64()
  end

  @doc false
  def escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end
end
