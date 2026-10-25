defmodule Authmk.Verification do
  @moduledoc """
  Single-use tokens for email links: email verification, password reset,
  email change and account deletion.

  A verification row stores `"<purpose>:<SHA-256 of the token>"` and a JSON
  payload. The token itself is only sent to the user.
  """

  alias Authmk.{Context, Error, Store, Token}

  @doc "Creates a token for `purpose` carrying `data`. Returns the token."
  @spec create(Context.t(), String.t(), map(), pos_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create(ctx, purpose, data, expires_in) do
    token = Token.generate()

    attrs = %{
      identifier: identifier(purpose, token),
      value: JSON.encode!(data),
      expires_at: DateTime.add(DateTime.utc_now(), expires_in)
    }

    with {:ok, _verification} <- Store.insert(ctx, :verification, attrs) do
      {:ok, token}
    end
  end

  @doc "Reads a token's data without using it up."
  @spec peek(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def peek(ctx, purpose, token) do
    with {:ok, verification} <- fetch(ctx, purpose, token) do
      {:ok, JSON.decode!(verification.value)}
    end
  end

  @doc "Reads a token's data and deletes it, so it works only once."
  @spec consume(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def consume(ctx, purpose, token) do
    with {:ok, verification} <- fetch(ctx, purpose, token),
         {:ok, _deleted} <- Store.delete(ctx, :verification, verification) do
      {:ok, JSON.decode!(verification.value)}
    end
  end

  defp fetch(ctx, purpose, token) when is_binary(token) do
    now = DateTime.utc_now()

    case Store.get_by(ctx, :verification, identifier: identifier(purpose, token)) do
      %{expires_at: expires_at} = verification ->
        if DateTime.after?(expires_at, now),
          do: {:ok, verification},
          else: {:error, Error.new(:invalid_token)}

      nil ->
        {:error, Error.new(:invalid_token)}
    end
  end

  defp fetch(_ctx, _purpose, _token), do: {:error, Error.new(:invalid_token)}

  defp identifier(purpose, token), do: "#{purpose}:#{Token.hash(token)}"
end
