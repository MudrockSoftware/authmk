defmodule Authmk.Plugins.SSO.SAML.Certificates do
  @moduledoc false
  # X.509 certificates and keys for SAML, with OTP's public_key: identity
  # providers' certificates (PEM, or the base64 that metadata carries) and
  # the service provider's own signing keys.

  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  @doc "A certificate (PEM or base64 DER) as `{:ok, %{der:, key:}}`, or `:error`."
  def parse(text) when is_binary(text) do
    with {:ok, der} <- der(text),
         {:ok, key} <- public_key(der) do
      {:ok, %{der: der, key: key}}
    end
  end

  def parse(_text), do: :error

  defp der(text) do
    case :public_key.pem_decode(text) do
      [{:Certificate, der, :not_encrypted}] ->
        {:ok, der}

      [] ->
        text |> String.replace(~r/\s+/, "") |> Base.decode64()

      _other ->
        :error
    end
  end

  defp public_key(der) do
    tbs = der |> :public_key.pkix_decode_cert(:otp) |> certificate(:tbsCertificate)
    info = tbs(tbs, :subjectPublicKeyInfo)

    case {key_info(info, :subjectPublicKey), algorithm(key_info(info, :algorithm), :parameters)} do
      {{:RSAPublicKey, _modulus, _exponent} = key, _parameters} ->
        {:ok, {:rsa, key}}

      {{:ECPoint, _point} = point, {:namedCurve, _curve} = curve} ->
        {:ok, {:ecdsa, {point, curve}}}

      _other ->
        :error
    end
  rescue
    _invalid -> :error
  catch
    _kind, _invalid -> :error
  end

  @doc "Whether `signature` (raw, as XML-DSig carries it) signs `data` with `certificate`'s key."
  def verify(data, hash, {:rsa, signature}, %{key: {:rsa, key}}),
    do: :public_key.verify(data, hash, signature, key)

  # XML-DSig's ECDSA signatures are r and s side by side; public_key wants DER.
  def verify(data, hash, {:ecdsa, signature}, %{key: {:ecdsa, key}})
      when rem(byte_size(signature), 2) == 0 do
    half = div(byte_size(signature), 2)
    <<r::binary-size(^half), s::binary-size(^half)>> = signature

    der =
      :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", unsigned(r), unsigned(s)})

    :public_key.verify(data, hash, der, key)
  end

  def verify(_data, _hash, _signature, _certificate), do: false

  defp unsigned(bytes), do: :binary.decode_unsigned(bytes)

  @doc "The service provider's RSA private key from PEM, or `:error`."
  def private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{type, _der, :not_encrypted} = entry] when type in [:RSAPrivateKey, :PrivateKeyInfo] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key -> {:ok, key}
          _other -> :error
        end

      _other ->
        :error
    end
  rescue
    _invalid -> :error
  end

  def private_key(_pem), do: :error

  @doc "Signs `data` with RSA and SHA-256."
  def sign(data, key), do: :public_key.sign(data, :sha256, key)

  @doc "A certificate as metadata's KeyInfo carries it: base64 DER."
  def base64(%{der: der}), do: Base.encode64(der)
end
