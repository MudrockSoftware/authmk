defmodule Authmk.Plugins.SSO.SAML.Signature do
  @moduledoc false
  # XML signatures (XML-DSig) on SAML elements, checked strictly:
  #
  #   * the Signature is a direct child of the element it signs, with one
  #     Reference, to that element's ID;
  #   * transforms are exactly enveloped-signature then exclusive c14n;
  #   * algorithms come from the allow-list below (no SHA-1);
  #   * the key is one of the identity provider's certificates from config,
  #     never one the message carries in KeyInfo.
  #
  # Callers then read only the element that was checked.

  alias Authmk.Plugins.SSO.SAML.{C14N, Certificates, XML}

  @ds "http://www.w3.org/2000/09/xmldsig#"
  @exc_c14n "http://www.w3.org/2001/10/xml-exc-c14n#"
  @enveloped "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
  @inclusive_ns "http://www.w3.org/2001/10/xml-exc-c14n#"

  @digests %{
    "http://www.w3.org/2001/04/xmlenc#sha256" => :sha256,
    "http://www.w3.org/2001/04/xmldsig-more#sha384" => :sha384,
    "http://www.w3.org/2001/04/xmlenc#sha512" => :sha512
  }

  @signatures %{
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256" => {:rsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha384" => {:rsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512" => {:rsa, :sha512},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256" => {:ecdsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha384" => {:ecdsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha512" => {:ecdsa, :sha512}
  }

  @doc "Whether `element` carries a Signature of its own."
  def signed?(element), do: XML.children(element, @ds, "Signature") != []

  @doc "`:ok` when `element`'s own signature checks out with one of `keys`."
  def verify(element, keys) do
    with {:ok, signature} <- one(XML.children(element, @ds, "Signature")),
         {:ok, signed_info} <- one(XML.children(signature, @ds, "SignedInfo")),
         {:ok, signed_info_prefixes} <- canonicalization(signed_info),
         {:ok, {key_type, hash}} <- signature_method(signed_info),
         {:ok, reference} <- one(XML.children(signed_info, @ds, "Reference")),
         :ok <- references(element, reference),
         {:ok, prefixes} <- transforms(reference),
         :ok <- digest(element, signature, reference, prefixes),
         {:ok, value} <- signature_value(signature, key_type) do
      data = C14N.canonicalize(signed_info, signed_info_prefixes)

      if Enum.any?(keys, &Certificates.verify(data, hash, value, &1)),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  defp one([element]), do: {:ok, element}
  defp one(_none_or_many), do: {:error, :invalid_signature}

  defp canonicalization(signed_info) do
    with %{} = method <- XML.child(signed_info, @ds, "CanonicalizationMethod"),
         @exc_c14n <- XML.attr(method, "Algorithm") do
      {:ok, inclusive_prefixes(method)}
    else
      _other -> {:error, :invalid_signature}
    end
  end

  defp signature_method(signed_info) do
    with %{} = method <- XML.child(signed_info, @ds, "SignatureMethod"),
         {:ok, algorithm} <- Map.fetch(@signatures, XML.attr(method, "Algorithm")) do
      {:ok, algorithm}
    else
      _other -> {:error, :unsupported_algorithm}
    end
  end

  # The reference names the signed element by its ID: nothing else.
  defp references(element, reference) do
    id = XML.attr(element, "ID")

    if is_binary(id) and id != "" and XML.attr(reference, "URI") == "#" <> id,
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp transforms(reference) do
    with %{} = transforms <- XML.child(reference, @ds, "Transforms"),
         [enveloped, c14n] <- XML.children(transforms, @ds, "Transform"),
         @enveloped <- XML.attr(enveloped, "Algorithm"),
         @exc_c14n <- XML.attr(c14n, "Algorithm") do
      {:ok, inclusive_prefixes(c14n)}
    else
      _other -> {:error, :invalid_signature}
    end
  end

  defp digest(element, signature, reference, prefixes) do
    with {:ok, hash} <- digest_method(reference),
         %{} = value <- XML.child(reference, @ds, "DigestValue"),
         {:ok, expected} <- base64(XML.text(value)) do
      # The enveloped-signature transform: the element without this signature.
      unsigned = %{element | children: Enum.reject(element.children, &(&1 == signature))}
      actual = :crypto.hash(hash, C14N.canonicalize(unsigned, prefixes))

      if Plug.Crypto.secure_compare(actual, expected),
        do: :ok,
        else: {:error, :invalid_digest}
    else
      {:error, :unsupported_algorithm} = error -> error
      _other -> {:error, :invalid_signature}
    end
  end

  defp digest_method(reference) do
    with %{} = method <- XML.child(reference, @ds, "DigestMethod"),
         {:ok, hash} <- Map.fetch(@digests, XML.attr(method, "Algorithm")) do
      {:ok, hash}
    else
      _other -> {:error, :unsupported_algorithm}
    end
  end

  defp signature_value(signature, key_type) do
    with %{} = value <- XML.child(signature, @ds, "SignatureValue"),
         {:ok, raw} <- base64(XML.text(value)) do
      {:ok, {key_type, raw}}
    else
      _other -> {:error, :invalid_signature}
    end
  end

  # <InclusiveNamespaces PrefixList="xs saml"/>, "#default" for the default.
  defp inclusive_prefixes(method) do
    case XML.child(method, @inclusive_ns, "InclusiveNamespaces") do
      nil ->
        []

      inclusive ->
        (XML.attr(inclusive, "PrefixList") || "")
        |> String.split()
        |> Enum.map(fn
          "#default" -> ""
          prefix -> prefix
        end)
    end
  end

  # Base64 in XML may be wrapped over lines.
  defp base64(text), do: text |> String.replace(~r/\s+/, "") |> Base.decode64()
end
