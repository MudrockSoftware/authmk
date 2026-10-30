defmodule Authmk.Payments.Webhook do
  @moduledoc false
  # Checks that a webhook comes from the payment provider: an HMAC-SHA256
  # over the exact body it sent (Authmk.Plug.RawBody), compared in constant
  # time, and recent (within @tolerance seconds), so a captured webhook
  # can't be replayed later. Each provider signs its own way:
  #
  #   * stripe/4: `Stripe-Signature: t=<unix>,v1=<hex>[,v1=<hex>]`, over
  #     "<t>.<body>";
  #   * standard/4: Standard Webhooks (`webhook-id`, `webhook-timestamp`,
  #     `webhook-signature: v1,<base64> [v1,<base64>]`), over
  #     "<id>.<timestamp>.<body>";
  #   * hex/3: a hex HMAC of the body alone, in one header.
  #
  # Several signatures in one header are how providers rotate secrets: any
  # one that matches will do.

  @tolerance 300

  @doc "Stripe's scheme. `secret`: the endpoint's `whsec_...` signing secret, as given."
  def stripe(header, body, secret, now \\ System.system_time(:second))

  def stripe(header, body, secret, now)
      when is_binary(header) and is_binary(body) and is_binary(secret) do
    parts =
      for part <- String.split(header, ","),
          [k, v] <- [String.split(part, "=", parts: 2)],
          do: {k, v}

    with {"t", timestamp} <- List.keyfind(parts, "t", 0),
         {timestamp, ""} <- Integer.parse(timestamp),
         :ok <- recent(timestamp, now) do
      expected = hmac(secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)
      signatures = for {"v1", signature} <- parts, do: signature
      matches(signatures, expected)
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :invalid_signature}
    end
  end

  def stripe(_header, _body, _secret, _now), do: {:error, :invalid_signature}

  @doc """
  Standard Webhooks. `key`: the HMAC key itself (providers say how they
  derive it from the secret they show).
  """
  def standard(headers, body, key, now \\ System.system_time(:second))

  def standard(%{id: id, timestamp: timestamp, signature: signature}, body, key, now)
      when is_binary(id) and is_binary(timestamp) and is_binary(signature) and is_binary(body) and
             is_binary(key) do
    with {timestamp_value, ""} <- Integer.parse(timestamp),
         :ok <- recent(timestamp_value, now) do
      expected = hmac(key, "#{id}.#{timestamp}.#{body}") |> Base.encode64()

      signatures =
        for entry <- String.split(signature, " ", trim: true),
            ["v1", value] <- [String.split(entry, ",", parts: 2)],
            do: value

      matches(signatures, expected)
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :invalid_signature}
    end
  end

  def standard(_headers, _body, _key, _now), do: {:error, :invalid_signature}

  @doc """
  The HMAC key of a Standard Webhooks secret: its base64 (after `whsec_`,
  when it has it), decoded. `nil` for anything else, so nothing verifies.
  """
  def standard_key("whsec_" <> encoded), do: standard_key(encoded)

  def standard_key(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when key != "" -> key
      _invalid -> nil
    end
  end

  def standard_key(_secret), do: nil

  @doc "A hex HMAC-SHA256 of the body alone (no timestamp: providers that sign only the body)."
  def hex(signature, body, secret)
      when is_binary(signature) and is_binary(body) and is_binary(secret) do
    expected = hmac(secret, body) |> Base.encode16(case: :lower)
    matches([String.downcase(String.trim(signature))], expected)
  end

  def hex(_signature, _body, _secret), do: {:error, :invalid_signature}

  defp recent(timestamp, now) do
    if abs(now - timestamp) <= @tolerance, do: :ok, else: {:error, :stale}
  end

  defp matches(signatures, expected) do
    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
