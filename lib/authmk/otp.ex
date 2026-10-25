defmodule Authmk.OTP do
  @moduledoc """
  One-time codes sent to a phone number or an email: issued for a `key`
  (the number or address), checked once.

  Codes are stored encrypted, so a leaked database or secondary storage
  doesn't give them away. A new code for the same key replaces the old one.
  Each check uses the stored code up and, after a wrong guess, stores it
  again with one more attempt counted, so requests racing to guess can't
  get more tries than `allowed_attempts`.

  Used by plugins like `Authmk.Plugins.PhoneNumber`.
  """

  alias Authmk.{Context, Crypto, Error, Verification}

  @doc """
  Issues a code for `key` and returns it, for the plugin to send.

  Options: `:length` (digits, default 6), `:expires_in` (seconds, default 300).
  """
  @spec issue(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def issue(%Context{config: config} = ctx, purpose, key, opts \\ []) do
    code = code(Keyword.get(opts, :length, 6))
    expires_in = Keyword.get(opts, :expires_in, 300)

    data = %{
      "code" => Crypto.encrypt(config, crypto_purpose(purpose), code),
      "attempts" => 0,
      "expires_at" => System.system_time(:second) + expires_in
    }

    :ok = Verification.delete(ctx, purpose, key)

    with {:ok, _key} <- Verification.create(ctx, purpose, data, expires_in, key) do
      {:ok, code}
    end
  end

  @doc """
  Checks `code` for `key`. Right uses it up; wrong counts an attempt, and
  after `:allowed_attempts` (default 3) the code is gone.
  """
  @spec verify(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def verify(ctx, purpose, key, code, opts \\ []) do
    with {:ok, data} <- take(ctx, purpose, key) do
      if matches?(ctx, purpose, data, code),
        do: :ok,
        else: wrong_guess(ctx, purpose, key, data, Keyword.get(opts, :allowed_attempts, 3))
    end
  end

  @doc """
  Checks `code` for `key` without using it up, so a later step can verify it
  (like a form that checks the code before asking for a new password). A
  wrong guess still counts.
  """
  @spec check(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def check(ctx, purpose, key, code, opts \\ []) do
    with {:ok, data} <- take(ctx, purpose, key) do
      if matches?(ctx, purpose, data, code),
        do: put_back(ctx, purpose, key, data),
        else: wrong_guess(ctx, purpose, key, data, Keyword.get(opts, :allowed_attempts, 3))
    end
  end

  defp put_back(ctx, purpose, key, data) do
    expires_in = data["expires_at"] - System.system_time(:second)

    with {:ok, _key} <- Verification.create(ctx, purpose, data, max(expires_in, 1), key), do: :ok
  end

  defp take(ctx, purpose, key) do
    case Verification.consume(ctx, purpose, key) do
      {:ok, %{"expires_at" => expires_at} = data} ->
        if expires_at > System.system_time(:second), do: {:ok, data}, else: invalid()

      {:error, _not_found} ->
        invalid()
    end
  end

  defp matches?(%Context{config: config}, purpose, %{"code" => encrypted}, code) do
    case Crypto.decrypt(config, crypto_purpose(purpose), encrypted) do
      {:ok, stored} -> is_binary(code) and Plug.Crypto.secure_compare(stored, code)
      :error -> false
    end
  end

  defp wrong_guess(ctx, purpose, key, data, allowed_attempts) do
    attempts = data["attempts"] + 1
    expires_in = data["expires_at"] - System.system_time(:second)

    if attempts >= allowed_attempts or expires_in <= 0 do
      {:error, Error.new(:too_many_attempts)}
    else
      with {:ok, _key} <-
             Verification.create(ctx, purpose, %{data | "attempts" => attempts}, expires_in, key) do
        invalid()
      end
    end
  end

  defp code(length) do
    max = Integer.pow(10, length)
    # 64 random bits: the modulo bias is far below one in a billion.
    <<number::64>> = :crypto.strong_rand_bytes(8)
    number |> rem(max) |> Integer.to_string() |> String.pad_leading(length, "0")
  end

  defp crypto_purpose(purpose), do: "otp:" <> purpose

  defp invalid, do: {:error, Error.new(:invalid_otp)}
end
