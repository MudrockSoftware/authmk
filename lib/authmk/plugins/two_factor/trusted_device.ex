defmodule Authmk.Plugins.TwoFactor.TrustedDevice do
  @moduledoc false
  # A signed cookie that lets this browser skip 2FA for a user. It names the
  # user's current 2FA setup, so turning 2FA off (or setting it up again)
  # ends every trusted device.

  alias Authmk.{Cookies, Crypto}

  @purpose "two-factor-trust"

  def trusted?(%{config: config} = ctx, user, two_factor) do
    now = System.system_time(:second)

    with signed when is_binary(signed) <- Cookies.get(ctx, :trust_device),
         {:ok, json} <- Crypto.verify(config, @purpose, signed),
         {:ok, %{"user" => user_id, "setup" => setup, "expires_at" => expires_at}} <-
           JSON.decode(json) do
      user_id == to_string(user.id) and setup == to_string(two_factor.id) and expires_at > now
    else
      _not_trusted -> false
    end
  end

  def put(%{config: config} = ctx, user, two_factor, opts) do
    max_age = opts[:trust_device_days] * 86_400

    json =
      JSON.encode!(%{
        "user" => to_string(user.id),
        "setup" => to_string(two_factor.id),
        "expires_at" => System.system_time(:second) + max_age
      })

    Cookies.put(ctx, :trust_device, Crypto.sign(config, @purpose, json), max_age)
  end

  def forget(ctx), do: Cookies.delete(ctx, :trust_device)
end
