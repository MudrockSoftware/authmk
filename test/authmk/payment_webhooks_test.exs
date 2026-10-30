defmodule Authmk.PaymentWebhooksTest do
  # The webhook checks against fixed vectors: the Standard Webhooks spec's
  # published example, and Stripe's header rules (rotation, v0 ignored).
  use ExUnit.Case, async: true

  alias Authmk.Payments.Webhook

  test "Standard Webhooks: the spec's test vector" do
    key = Webhook.standard_key("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")

    headers = %{
      id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
      timestamp: "1614265330",
      signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    }

    body = ~s({"test": 2432232314})
    assert Webhook.standard(headers, body, key, 1_614_265_330) == :ok

    # One byte changed, another id, too late, or no v1: no.
    assert Webhook.standard(headers, body <> " ", key, 1_614_265_330) ==
             {:error, :invalid_signature}

    assert Webhook.standard(%{headers | id: "msg_other"}, body, key, 1_614_265_330) ==
             {:error, :invalid_signature}

    assert Webhook.standard(headers, body, key, 1_614_265_330 + 301) == {:error, :stale}
    v2 = %{headers | signature: "v2,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="}
    assert Webhook.standard(v2, body, key, 1_614_265_330) == {:error, :invalid_signature}

    # Rotation: several signatures, any one may match.
    rotated = %{
      headers
      | signature: "v1,bm90IHRoaXMgb25l v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    }

    assert Webhook.standard(rotated, body, key, 1_614_265_330) == :ok
  end

  test "Standard Webhooks secrets: with or without whsec_; anything else verifies nothing" do
    assert Webhook.standard_key("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw") ==
             Webhook.standard_key("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")

    for secret <- ["whsec_not base64!", "whsec_", "", nil] do
      assert Webhook.standard_key(secret) == nil

      assert Webhook.standard(
               %{id: "msg_1", timestamp: "1", signature: "v1,AAAA"},
               "{}",
               Webhook.standard_key(secret),
               1
             ) == {:error, :invalid_signature}
    end
  end

  test "Stripe: v1 signatures over the timestamp and body; v0 never counts" do
    body = ~s({"id":"evt_1"})
    t = 1_700_000_000
    good = :crypto.mac(:hmac, :sha256, "whsec_abc", "#{t}.#{body}") |> Base.encode16(case: :lower)

    other =
      :crypto.mac(:hmac, :sha256, "whsec_old", "#{t}.#{body}") |> Base.encode16(case: :lower)

    assert Webhook.stripe("t=#{t},v1=#{good}", body, "whsec_abc", t) == :ok
    # Two secrets during rotation: either signature does.
    assert Webhook.stripe("t=#{t},v1=#{other},v1=#{good}", body, "whsec_abc", t) == :ok
    # A v0 signature (Stripe's fake scheme on test events) is ignored.
    assert Webhook.stripe("t=#{t},v0=#{good}", body, "whsec_abc", t) ==
             {:error, :invalid_signature}

    # The timestamp is signed too.
    assert Webhook.stripe("t=#{t + 1},v1=#{good}", body, "whsec_abc", t) ==
             {:error, :invalid_signature}

    assert Webhook.stripe("t=#{t},v1=#{good}", body, "whsec_abc", t + 301) == {:error, :stale}
    assert Webhook.stripe("garbage", body, "whsec_abc", t) == {:error, :invalid_signature}
    assert Webhook.stripe(nil, body, "whsec_abc", t) == {:error, :invalid_signature}
  end

  test "hex HMAC of the body" do
    signature = :crypto.mac(:hmac, :sha256, "secret", "body") |> Base.encode16(case: :lower)
    assert Webhook.hex(signature, "body", "secret") == :ok
    assert Webhook.hex(String.upcase(signature), "body", "secret") == :ok
    assert Webhook.hex(signature, "body!", "secret") == {:error, :invalid_signature}
    assert Webhook.hex(nil, "body", "secret") == {:error, :invalid_signature}
  end
end
