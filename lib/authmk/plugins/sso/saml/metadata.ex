defmodule Authmk.Plugins.SSO.SAML.Metadata do
  @moduledoc false
  # SAML metadata: ours (the service provider's, for the identity provider's
  # admin), and theirs (an IdP's, pasted in when registering a provider).

  alias Authmk.Plugins.SSO.SAML.{Certificates, Request, XML}

  @md "urn:oasis:names:tc:SAML:2.0:metadata"
  @ds "http://www.w3.org/2000/09/xmldsig#"
  @redirect "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
  @post "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"

  @doc """
  The service provider's metadata. `sp`: `:entity_id`, `:acs_url`,
  `:certificates` (all published, for rotation), `:signs_requests`,
  `:name_id_format`.
  """
  def service_provider(sp) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<md:EntityDescriptor xmlns:md="#{@md}" entityID="#{Request.escape(sp.entity_id)}">),
      ~s(<md:SPSSODescriptor AuthnRequestsSigned="#{sp.signs_requests}" ),
      ~s(WantAssertionsSigned="true" ),
      ~s(protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">),
      Enum.map(sp.certificates, &key_descriptor/1),
      ~s(<md:NameIDFormat>#{Request.escape(sp.name_id_format)}</md:NameIDFormat>),
      ~s(<md:AssertionConsumerService Binding="#{@post}" ),
      ~s(Location="#{Request.escape(sp.acs_url)}" index="0" isDefault="true"/>),
      ~s(</md:SPSSODescriptor></md:EntityDescriptor>)
    ])
  end

  defp key_descriptor(certificate) do
    [
      ~s(<md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="#{@ds}"><ds:X509Data>),
      ~s(<ds:X509Certificate>#{Certificates.base64(certificate)}</ds:X509Certificate>),
      ~s(</ds:X509Data></ds:KeyInfo></md:KeyDescriptor>)
    ]
  end

  @doc """
  An identity provider's metadata, as `{:ok, %{entity_id:, sso_url:,
  certificates: [pem_or_base64]}}` or `{:error, description}`. Only the
  HTTP-Redirect sign-on service is used.
  """
  def identity_provider(xml) do
    with {:ok, %{ns: @md, name: "EntityDescriptor"} = entity} <- XML.parse(xml),
         entity_id when is_binary(entity_id) <- XML.attr(entity, "entityID"),
         %{} = idp <- XML.child(entity, @md, "IDPSSODescriptor"),
         sso_url when is_binary(sso_url) <- redirect_service(idp),
         [_ | _] = certificates <- signing_certificates(idp) do
      {:ok, %{entity_id: entity_id, sso_url: sso_url, certificates: certificates}}
    else
      _invalid ->
        {:error,
         "metadata must be one EntityDescriptor with an IDPSSODescriptor, an HTTP-Redirect SingleSignOnService and a signing certificate"}
    end
  end

  defp redirect_service(idp) do
    idp
    |> XML.children(@md, "SingleSignOnService")
    |> Enum.find_value(&(XML.attr(&1, "Binding") == @redirect and XML.attr(&1, "Location")))
  end

  # Keys for signing, or for any use when `use` is left out.
  defp signing_certificates(idp) do
    for descriptor <- XML.children(idp, @md, "KeyDescriptor"),
        XML.attr(descriptor, "use") in [nil, "signing"],
        info <- XML.children(descriptor, @ds, "KeyInfo"),
        data <- XML.children(info, @ds, "X509Data"),
        certificate <- XML.children(data, @ds, "X509Certificate"),
        do: XML.text(certificate)
  end
end
