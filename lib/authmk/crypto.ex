defmodule Authmk.Crypto do
  @moduledoc """
  Signing and encryption with the configured secrets.

  Every use has a `purpose` (like `"session-token"`), and each purpose gets
  its own key, derived from the secret with HKDF-SHA256. A value signed for
  one purpose can't be replayed for another.

  Output carries the secret version (`v2.`), so values made with an older
  secret still verify while it stays in the `secrets` list. Signing uses
  `Plug.Crypto.MessageVerifier` (HMAC-SHA256); encryption uses
  `Plug.Crypto.MessageEncryptor` (AES-GCM).
  """

  alias Authmk.Config
  alias Plug.Crypto.{MessageEncryptor, MessageVerifier}

  @salt "authmk:v1"

  @doc "Signs `data`. The result is readable, but can't be changed."
  @spec sign(Config.t(), String.t(), binary()) :: String.t()
  def sign(config, purpose, data) do
    {version, key} = current_key(config, purpose)
    "v#{version}." <> MessageVerifier.sign(data, key)
  end

  @doc "Returns the signed data, or `:error` when the signature doesn't match."
  @spec verify(Config.t(), String.t(), String.t()) :: {:ok, binary()} | :error
  def verify(config, purpose, signed) do
    with {:ok, key, message} <- split(config, purpose, signed) do
      MessageVerifier.verify(message, key)
    end
  end

  @doc "Encrypts `data`. The result is neither readable nor changeable."
  @spec encrypt(Config.t(), String.t(), binary()) :: String.t()
  def encrypt(config, purpose, data) do
    {version, key} = current_key(config, purpose)
    "v#{version}." <> MessageEncryptor.encrypt(data, key, sign_key(key))
  end

  @doc "Decrypts data from `encrypt/3`, or returns `:error`."
  @spec decrypt(Config.t(), String.t(), String.t()) :: {:ok, binary()} | :error
  def decrypt(config, purpose, encrypted) do
    with {:ok, key, message} <- split(config, purpose, encrypted) do
      MessageEncryptor.decrypt(message, key, sign_key(key))
    end
  end

  @doc "HKDF-SHA256 (RFC 5869) with a 32-byte output."
  @spec derive_key(String.t(), String.t()) :: binary()
  def derive_key(secret, purpose) do
    prk = :crypto.mac(:hmac, :sha256, @salt, secret)
    :crypto.mac(:hmac, :sha256, prk, "authmk:#{purpose}:v1" <> <<1>>)
  end

  # MessageEncryptor wants a second, independent key for its key wrapping.
  defp sign_key(key), do: :crypto.mac(:hmac, :sha256, key, "authmk:encryption-sign:v1")

  defp current_key(config, purpose) do
    [{version, secret} | _older] = config.secrets
    {version, derive_key(secret, purpose)}
  end

  defp split(config, purpose, "v" <> rest) do
    with [version, message] <- String.split(rest, ".", parts: 2),
         {version, ""} <- Integer.parse(version),
         {^version, secret} <- List.keyfind(config.secrets, version, 0) do
      {:ok, derive_key(secret, purpose), message}
    else
      _ -> :error
    end
  end

  defp split(_config, _purpose, _value), do: :error
end
