defmodule Authmk.PasswordPolicy do
  @moduledoc """
  Checks new passwords against a minimum and maximum length. Plugins that
  set passwords (email and password, phone number, email OTP) share it.
  """

  alias Authmk.{Config, Context, Error}

  @doc """
  `check_length/3`, then what the password hasher can take in full (see
  `c:Authmk.Password.max_bytes/0`): `:ok`, or `:password_too_short` /
  `:password_too_long`.
  """
  @spec check(Context.t() | Config.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, Error.t()}
  def check(ctx_or_config, password, min, max) do
    with :ok <- check_length(password, min, max), do: check_hashable(ctx_or_config, password)
  end

  @doc "`:password_too_long` when the password hasher would ignore some of the password."
  @spec check_hashable(Context.t() | Config.t(), String.t()) :: :ok | {:error, Error.t()}
  def check_hashable(%Context{config: config}, password), do: check_hashable(config, password)

  def check_hashable(%{password_hasher: hasher}, password) do
    if Code.ensure_loaded?(hasher) and function_exported?(hasher, :max_bytes, 0) and
         byte_size(password) > hasher.max_bytes(),
       do: {:error, Error.new(:password_too_long)},
       else: :ok
  end

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
