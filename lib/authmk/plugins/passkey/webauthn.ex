defmodule Authmk.Plugins.Passkey.WebAuthn do
  @moduledoc false
  # The WebAuthn ceremonies, through Wax: options for the browser, and
  # checking what the browser sends back. Binary fields travel as base64url.
  #
  # Wax is an optional dependency: this module compiles without it, and the
  # plugin refuses to start when it's missing.
  @compile {:no_warn_undefined, [Wax, Wax.AuthenticatorData, CBOR]}

  def creation_options(challenge, user, user_handle, excluded, settings) do
    %{
      "challenge" => encode(challenge.bytes),
      "rp" => %{"id" => challenge.rp_id, "name" => settings.rp_name},
      "user" => %{
        "id" => encode(user_handle),
        "name" => user.email,
        "displayName" => user.name || user.email
      },
      "pubKeyCredParams" => [
        %{"type" => "public-key", "alg" => -7},
        %{"type" => "public-key", "alg" => -8},
        %{"type" => "public-key", "alg" => -257}
      ],
      "timeout" => settings.timeout * 1000,
      "excludeCredentials" => Enum.map(excluded, &descriptor/1),
      "authenticatorSelection" => %{
        "residentKey" => "preferred",
        "userVerification" => settings.user_verification
      },
      "attestation" => "none",
      "extensions" => settings.extensions
    }
  end

  def request_options(challenge, allowed, settings) do
    %{
      "challenge" => encode(challenge.bytes),
      "rpId" => challenge.rp_id,
      "timeout" => settings.timeout * 1000,
      "userVerification" => settings.user_verification,
      "allowCredentials" => Enum.map(allowed, &descriptor/1),
      "extensions" => settings.extensions
    }
  end

  def new_registration_challenge(settings, bytes \\ nil),
    do: settings |> wax_opts(bytes) |> Wax.new_registration_challenge()

  def new_authentication_challenge(settings, bytes \\ nil),
    do: settings |> wax_opts(bytes) |> Wax.new_authentication_challenge()

  @doc "Checks a registration response. Returns the new credential."
  def register(%{"response" => response}, challenge) do
    with {:ok, attestation} <- decode(response["attestationObject"]),
         {:ok, client_data} <- decode(response["clientDataJSON"]),
         {:ok, {auth_data, _attestation}} <-
           safely(fn -> Wax.register(attestation, client_data, challenge) end) do
      credential = auth_data.attested_credential_data

      {:ok,
       %{
         credential_id: credential.credential_id,
         public_key: credential.credential_public_key,
         sign_count: auth_data.sign_count,
         aaguid: aaguid(Wax.AuthenticatorData.get_aaguid(auth_data)),
         backup_eligible: auth_data.flag_backup_eligible,
         backed_up: auth_data.flag_credential_backed_up,
         transports: List.wrap(response["transports"])
       }}
    else
      _invalid -> :error
    end
  end

  def register(_response, _challenge), do: :error

  @doc "Checks a sign-in response against the stored credential."
  def authenticate(%{"response" => response}, credential_id, public_key, challenge) do
    with {:ok, auth_data} <- decode(response["authenticatorData"]),
         {:ok, signature} <- decode(response["signature"]),
         {:ok, client_data} <- decode(response["clientDataJSON"]),
         {:ok, result} <-
           safely(fn ->
             Wax.authenticate(credential_id, auth_data, signature, client_data, challenge, [
               {credential_id, public_key}
             ])
           end) do
      {:ok, %{sign_count: result.sign_count, user_verified: result.flag_user_verified}}
    else
      _invalid -> :error
    end
  end

  def authenticate(_response, _credential_id, _public_key, _challenge), do: :error

  # Wax raises on some malformed input (like CBOR tags in authenticator
  # data) instead of returning an error. Either way the response is invalid.
  defp safely(fun) do
    fun.()
  rescue
    _malformed -> {:error, :malformed}
  end

  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  # Clients send base64url, padded or not.
  def decode(value) when is_binary(value),
    do: value |> String.trim_trailing("=") |> Base.url_decode64(padding: false)

  def decode(_value), do: :error

  # COSE keys are stored as CBOR, the format authenticators use.
  def encode_key(cose_key) do
    cose_key
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, bytes(v)}
      pair -> pair
    end)
    |> CBOR.encode()
    |> Base.encode64()
  end

  def decode_key(stored) do
    {:ok, key, ""} = stored |> Base.decode64!() |> CBOR.decode()

    Map.new(key, fn
      {k, %{__struct__: CBOR.Tag, tag: :bytes, value: v}} -> {k, v}
      pair -> pair
    end)
  end

  # A CBOR byte string (a %CBOR.Tag{}, without needing CBOR to compile).
  defp bytes(value), do: %{__struct__: CBOR.Tag, tag: :bytes, value: value}

  defp descriptor(passkey) do
    transports = if passkey.transports, do: String.split(passkey.transports, ","), else: []
    %{"type" => "public-key", "id" => passkey.credential_id, "transports" => transports}
  end

  defp wax_opts(settings, bytes) do
    opts = [
      origin: settings.origin,
      rp_id: settings.rp_id,
      user_verification: settings.user_verification,
      timeout: settings.timeout,
      attestation: "none"
    ]

    if bytes, do: [bytes: bytes] ++ opts, else: opts
  end

  defp aaguid(nil), do: nil

  defp aaguid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end
end
