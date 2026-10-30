defmodule Authmk.Plugins.SSO.SAML.Decrypt do
  @moduledoc false
  # Encrypted assertions (XML Encryption), decrypted with the service
  # provider's keys, by OTP's public_key and crypto:
  #
  #   * the content key comes wrapped with RSA-OAEP (rsa-oaep-mgf1p, or
  #     xmlenc11#rsa-oaep with SHA-1 or SHA-256); RSA 1.5 is refused for its
  #     padding oracles;
  #   * the assertion is encrypted with AES-GCM (128 or 256), or AES-CBC
  #     only with `allow_aes_cbc` (XML Encryption's CBC mode has known
  #     padding-oracle attacks, so failures all look the same);
  #   * the plaintext is read with the same safe parser, inside the
  #     namespaces in scope where it was, and must be one Assertion.
  #
  # The decrypted assertion is checked like any other: it must be signed.

  alias Authmk.Plugins.SSO.SAML.XML

  @xenc "http://www.w3.org/2001/04/xmlenc#"
  @xenc11 "http://www.w3.org/2009/xmlenc11#"
  @ds "http://www.w3.org/2000/09/xmldsig#"
  @assertion "urn:oasis:names:tc:SAML:2.0:assertion"

  @gcm %{
    "http://www.w3.org/2009/xmlenc11#aes128-gcm" => {:aes_128_gcm, 16},
    "http://www.w3.org/2009/xmlenc11#aes256-gcm" => {:aes_256_gcm, 32}
  }

  @cbc %{
    "http://www.w3.org/2001/04/xmlenc#aes128-cbc" => {:aes_128_cbc, 16},
    "http://www.w3.org/2001/04/xmlenc#aes256-cbc" => {:aes_256_cbc, 32}
  }

  @digests %{
    nil => :sha,
    "http://www.w3.org/2000/09/xmldsig#sha1" => :sha,
    "http://www.w3.org/2001/04/xmlenc#sha256" => :sha256
  }

  @doc "The Assertion in an EncryptedAssertion, or `{:error, :undecryptable}`."
  def assertion(encrypted, keys, allow_cbc) do
    with %{} = data <- XML.child(encrypted, @xenc, "EncryptedData"),
         {:ok, cipher} <- content_cipher(data, allow_cbc),
         %{} = encrypted_key <- encrypted_key(encrypted, data),
         {:ok, content_key} <- content_key(encrypted_key, keys, elem(cipher, 1)),
         {:ok, ciphertext} <- cipher_value(data),
         {:ok, plaintext} <- decrypt(cipher, content_key, ciphertext),
         {:ok, assertion} <- parse(plaintext, encrypted.scope) do
      {:ok, assertion}
    else
      _failed -> {:error, :undecryptable}
    end
  end

  defp content_cipher(data, allow_cbc) do
    algorithm = data |> XML.child(@xenc, "EncryptionMethod") |> algorithm()

    cond do
      cipher = @gcm[algorithm] -> {:ok, cipher}
      allow_cbc and Map.has_key?(@cbc, algorithm) -> {:ok, @cbc[algorithm]}
      true -> :error
    end
  end

  # In the EncryptedData's KeyInfo, or next to it (as Shibboleth does).
  defp encrypted_key(encrypted, data) do
    with nil <- data |> XML.child(@ds, "KeyInfo") |> key_in(),
         do: XML.child(encrypted, @xenc, "EncryptedKey")
  end

  defp key_in(nil), do: nil
  defp key_in(key_info), do: XML.child(key_info, @xenc, "EncryptedKey")

  # RSA-OAEP with one of the service provider's keys, for the right key size.
  defp content_key(encrypted_key, keys, size) do
    with {:ok, options} <- oaep(XML.child(encrypted_key, @xenc, "EncryptionMethod")),
         {:ok, wrapped} <- cipher_value(encrypted_key) do
      Enum.find_value(keys, :error, &sized(unwrap(wrapped, &1.key, options), size))
    end
  end

  defp sized(content_key, size) when byte_size(content_key) == size, do: {:ok, content_key}
  defp sized(_wrong, _size), do: nil

  defp unwrap(wrapped, key, options) do
    :public_key.decrypt_private(wrapped, key, options)
  rescue
    _failed -> ""
  catch
    _kind, _failed -> ""
  end

  defp oaep(%{} = method) do
    digest = method |> XML.child(@ds, "DigestMethod") |> algorithm()

    case {algorithm(method), Map.fetch(@digests, digest)} do
      {@xenc <> "rsa-oaep-mgf1p", {:ok, md}} ->
        {:ok, rsa_oaep(md, :sha)}

      {@xenc11 <> "rsa-oaep", {:ok, md}} ->
        with {:ok, mgf} <- mgf(XML.child(method, @xenc11, "MGF")), do: {:ok, rsa_oaep(md, mgf)}

      _other ->
        :error
    end
  end

  defp oaep(_missing), do: :error

  defp mgf(nil), do: {:ok, :sha}

  defp mgf(element) do
    case algorithm(element) do
      @xenc11 <> "mgf1sha1" -> {:ok, :sha}
      @xenc11 <> "mgf1sha256" -> {:ok, :sha256}
      _other -> :error
    end
  end

  defp rsa_oaep(md, mgf),
    do: [{:rsa_padding, :rsa_pkcs1_oaep_padding}, {:rsa_oaep_md, md}, {:rsa_mgf1_md, mgf}]

  defp cipher_value(element) do
    with %{} = data <- XML.child(element, @xenc, "CipherData"),
         %{} = value <- XML.child(data, @xenc, "CipherValue") do
      value |> XML.text() |> String.replace(~r/\s+/, "") |> Base.decode64()
    else
      _missing -> :error
    end
  end

  # GCM: a 12-byte IV, the ciphertext, a 16-byte tag.
  defp decrypt({cipher, _size}, key, <<iv::binary-12, rest::binary>>)
       when cipher in [:aes_128_gcm, :aes_256_gcm] and byte_size(rest) > 16 do
    ciphertext_size = byte_size(rest) - 16
    <<ciphertext::binary-size(^ciphertext_size), tag::binary-16>> = rest

    case :crypto.crypto_one_time_aead(cipher, key, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  # CBC: a 16-byte IV; the last byte says how much padding to drop.
  defp decrypt({cipher, _size}, key, <<iv::binary-16, ciphertext::binary>>)
       when cipher in [:aes_128_cbc, :aes_256_cbc] and ciphertext != "" and
              rem(byte_size(ciphertext), 16) == 0 do
    padded = :crypto.crypto_one_time(cipher, key, iv, ciphertext, false)
    padding = :binary.last(padded)

    if padding in 1..16,
      do: {:ok, binary_part(padded, 0, byte_size(padded) - padding)},
      else: :error
  end

  defp decrypt(_cipher, _key, _ciphertext), do: :error

  # The plaintext uses the prefixes declared around the EncryptedAssertion.
  defp parse(plaintext, scope) do
    declarations =
      for {prefix, uri} <- scope, prefix != "xml", into: "" do
        name = if prefix == "", do: "xmlns", else: "xmlns:" <> prefix
        ~s( #{name}="#{escape(uri)}")
      end

    xml = "<authmk-decrypted#{declarations}>" <> plaintext <> "</authmk-decrypted>"

    with {:ok, wrapper} <- XML.parse(xml),
         {elements, texts} = Enum.split_with(wrapper.children, &is_map/1),
         true <- Enum.all?(texts, &(String.trim(&1) == "")),
         [%{ns: @assertion, name: "Assertion"} = assertion] <- elements do
      {:ok, assertion}
    else
      _other -> :error
    end
  end

  defp algorithm(nil), do: nil
  defp algorithm(element), do: XML.attr(element, "Algorithm")

  defp escape(uri), do: uri |> String.replace("&", "&amp;") |> String.replace(~s("), "&quot;")
end
