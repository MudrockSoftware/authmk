defmodule Authmk.Testing.FakeAuthenticator do
  @moduledoc """
  A software passkey for tests: answers WebAuthn options the way a browser
  and an authenticator would, with an EC P-256 key and "none" attestation.
  Needs `{:wax_, "~> 0.7"}`, like `Authmk.Plugins.Passkey`.

      authenticator = Authmk.Testing.FakeAuthenticator.new(origin: "http://localhost:4000")

      # Registration: send `response` to /passkey/verify-registration.
      response = FakeAuthenticator.register(authenticator, creation_options)

      # Sign-in: keep the returned authenticator, its counter moved.
      {authenticator, response} = FakeAuthenticator.authenticate(authenticator, request_options)

  Options for `new/1`: `origin:` (the page's origin), `user_verified:`
  (default `true`), `backup_eligible:`, `aaguid:` (16 bytes), `counts:`
  (`false` for a sign count that stays 0, like most platform passkeys).
  """

  @compile {:no_warn_undefined, [CBOR]}

  defstruct [
    :key,
    :credential_id,
    origin: "http://localhost:4000",
    sign_count: 0,
    counts: true,
    user_verified: true,
    backup_eligible: false,
    aaguid: <<0::128>>
  ]

  @type t :: %__MODULE__{}

  @doc "A new authenticator with a fresh key and credential id."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(
      %__MODULE__{
        key: :public_key.generate_key({:namedCurve, :secp256r1}),
        credential_id: :crypto.strong_rand_bytes(32)
      },
      opts
    )
  end

  @doc "A `credential.toJSON()` for registration options."
  @spec register(t(), map()) :: map()
  def register(authenticator, %{"challenge" => challenge, "rp" => %{"id" => rp_id}}) do
    client_data = client_data(authenticator, "webauthn.create", challenge)
    auth_data = auth_data(authenticator, rp_id, attested_credential(authenticator))

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => bytes(auth_data)
      })

    %{
      "id" => encode(authenticator.credential_id),
      "rawId" => encode(authenticator.credential_id),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" => encode(client_data),
        "attestationObject" => encode(attestation),
        "transports" => ["internal", "hybrid"]
      }
    }
  end

  @doc "A `credential.toJSON()` for sign-in options, and the authenticator with its count moved."
  @spec authenticate(t(), map()) :: {t(), map()}
  def authenticate(authenticator, %{"challenge" => challenge, "rpId" => rp_id}) do
    authenticator =
      if authenticator.counts,
        do: %{authenticator | sign_count: authenticator.sign_count + 1},
        else: authenticator

    client_data = client_data(authenticator, "webauthn.get", challenge)
    auth_data = auth_data(authenticator, rp_id, <<>>)

    signature =
      :public_key.sign(
        auth_data <> :crypto.hash(:sha256, client_data),
        :sha256,
        authenticator.key
      )

    response = %{
      "id" => encode(authenticator.credential_id),
      "rawId" => encode(authenticator.credential_id),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" => encode(client_data),
        "authenticatorData" => encode(auth_data),
        "signature" => encode(signature),
        "userHandle" => nil
      }
    }

    {authenticator, response}
  end

  defp client_data(authenticator, type, challenge) do
    JSON.encode!(%{
      "type" => type,
      "challenge" => challenge,
      "origin" => authenticator.origin,
      "crossOrigin" => false
    })
  end

  # rpIdHash | flags | signCount | attested credential data
  defp auth_data(authenticator, rp_id, attested) do
    import Bitwise

    flags =
      0x01
      |> bor(if authenticator.user_verified, do: 0x04, else: 0)
      |> bor(if authenticator.backup_eligible, do: 0x18, else: 0)
      |> bor(if attested != <<>>, do: 0x40, else: 0)

    :crypto.hash(:sha256, rp_id) <> <<flags, authenticator.sign_count::32>> <> attested
  end

  defp attested_credential(authenticator) do
    id = authenticator.credential_id
    authenticator.aaguid <> <<byte_size(id)::16>> <> id <> cose_key(authenticator)
  end

  defp cose_key(%{key: key}) do
    {:ECPrivateKey, _version, _private, _params, <<4, x::binary-32, y::binary-32>>, _attrs} = key

    CBOR.encode(%{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => bytes(x),
      -3 => bytes(y)
    })
  end

  defp bytes(value), do: %{__struct__: CBOR.Tag, tag: :bytes, value: value}

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
