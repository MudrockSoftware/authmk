defmodule Authmk.Plugins.JWT.Keys do
  @moduledoc false
  # Signing keys: made when needed, rotated after `rotation_interval`, kept
  # in the JWKS for `grace_period` after that, private halves encrypted.

  alias Authmk.Crypto

  @purpose "jwt-private-key"

  @doc "The key to sign with: the newest one in its rotation interval, or a new one."
  def current(ctx, opts) do
    case Enum.find(
           opts[:key_store].list(ctx),
           &(&1.algorithm == opts[:algorithm] and fresh?(&1, opts))
         ) do
      nil -> create(ctx, opts)
      key -> {:ok, key}
    end
  end

  @doc "The keys that verify tokens: those not past their rotation and grace period."
  def published(ctx, opts) do
    Enum.filter(opts[:key_store].list(ctx), &published?(&1, opts))
  end

  @doc "The private JWK of a key."
  def private_jwk(ctx, key, opts) do
    json =
      if opts[:encrypt_private_keys] do
        {:ok, json} = Crypto.decrypt(ctx.config, @purpose, key.private_key)
        json
      else
        key.private_key
      end

    JOSE.JWK.from_map(JSON.decode!(json))
  end

  @doc "A key's public half as a JWKS entry."
  def jwks_entry(key) do
    key.public_key
    |> JSON.decode!()
    |> Map.merge(%{"kid" => key.id, "alg" => key.algorithm, "use" => "sig"})
  end

  defp create(ctx, opts) do
    jwk = JOSE.JWK.generate_key(key_type(opts[:algorithm]))
    {_kty, private} = JOSE.JWK.to_map(jwk)
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    private_json = JSON.encode!(private)

    opts[:key_store].insert(ctx, %{
      public_key: JSON.encode!(public),
      private_key:
        if(opts[:encrypt_private_keys],
          do: Crypto.encrypt(ctx.config, @purpose, private_json),
          else: private_json
        ),
      algorithm: opts[:algorithm]
    })
  end

  defp key_type("EdDSA"), do: {:okp, :Ed25519}
  defp key_type("ES256"), do: {:ec, "P-256"}
  defp key_type("ES384"), do: {:ec, "P-384"}
  defp key_type("ES512"), do: {:ec, "P-521"}
  defp key_type(_rsa_or_pss), do: {:rsa, 2048}

  defp fresh?(key, opts) do
    case opts[:rotation_interval] do
      nil -> true
      interval -> age(key) < interval
    end
  end

  defp published?(key, opts) do
    case opts[:rotation_interval] do
      nil -> true
      interval -> age(key) < interval + opts[:grace_period]
    end
  end

  defp age(key), do: DateTime.diff(DateTime.utc_now(), key.inserted_at)
end
