defmodule Authmk.Plugins.TwoFactor.Challenge do
  @moduledoc false
  # A sign-in waiting for its second factor: a single-use token in the
  # `two_factor` cookie, pointing at its data (user, remember me, attempts,
  # one-time code). Every check uses the token up and, after a wrong code,
  # issues a new one with one more attempt counted. Requests racing with the
  # same token can't both check a code.

  alias Authmk.{Context, Cookies, Crypto, Error, Verification}

  @purpose "two-factor"

  @doc ~s(A new challenge's data. `kind` is "sign_in", or "enable" to turn 2FA on.)
  def new(user, remember_me, kind, opts) do
    %{
      "user_id" => to_string(user.id),
      "remember_me" => remember_me,
      "kind" => kind,
      "attempts" => 0,
      "expires_at" => System.system_time(:second) + opts[:challenge_expires_in]
    }
  end

  @doc "Takes this browser's challenge: `{:ok, data, ctx}` (the cookie deleted), or `:none`."
  def take(%Context{config: config} = ctx) do
    with signed when is_binary(signed) <- Cookies.get(ctx, :two_factor),
         {:ok, token} <- Crypto.verify(config, @purpose, signed),
         {:ok, data} <- Verification.consume(ctx, @purpose, token),
         true <- data["expires_at"] > System.system_time(:second) do
      {:ok, data, Cookies.delete(ctx, :two_factor)}
    else
      _no_challenge -> :none
    end
  end

  @doc "Puts the challenge back, with `data` changed (like a new one-time code)."
  def put(%Context{config: config} = ctx, data) do
    expires_in = max(data["expires_at"] - System.system_time(:second), 1)

    with {:ok, token} <- Verification.create(ctx, @purpose, data, expires_in) do
      {:ok, Cookies.put(ctx, :two_factor, Crypto.sign(config, @purpose, token), expires_in)}
    end
  end

  @doc "A wrong code: counts the attempt, and ends the challenge after too many."
  def failed(ctx, data, opts) do
    attempts = data["attempts"] + 1

    if attempts >= opts[:max_attempts] do
      {:error, too_many_attempts(), ctx}
    else
      with {:ok, ctx} <- put(ctx, %{data | "attempts" => attempts}) do
        {:error, invalid_code(), ctx}
      end
    end
  end

  def invalid_code,
    do: Error.custom(:invalid_two_factor_code, 401, "The code is invalid or has expired")

  def expired,
    do: Error.custom(:two_factor_expired, 401, "Sign in again: the two-factor step expired")

  defp too_many_attempts,
    do: Error.custom(:too_many_two_factor_attempts, 429, "Too many wrong codes. Sign in again")
end
