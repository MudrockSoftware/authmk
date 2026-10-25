defmodule Authmk.PasswordPolicy do
  @moduledoc """
  Checks new passwords against a minimum and maximum length. Plugins that
  set passwords (email and password, phone number, email OTP) share it.
  """

  alias Authmk.Error

  @doc "`:ok`, or `:password_too_short` / `:password_too_long`."
  @spec check_length(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, Error.t()}
  def check_length(password, min, max) do
    length = String.length(password)

    cond do
      length < min -> {:error, Error.new(:password_too_short)}
      length > max -> {:error, Error.new(:password_too_long)}
      true -> :ok
    end
  end
end
